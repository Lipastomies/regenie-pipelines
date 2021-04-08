task step2 {

    Array[String] phenolist
    File cov_pheno
    String covariates
    Boolean is_binary
    File bgen
    File bgi = bgen + ".bgi"
    File sample = bgen + ".sample"
    File pred
    String prefix = sub(basename(pred), "_pred.list", "") + "___" + basename(bgen)
    Array[File] loco
    Int bsize
    String options

    String docker

    command <<<

        n_cpu=`grep -c ^processor /proc/cpuinfo`

        # move loco files to /cromwell_root as pred file paths point there
        for file in ${sep=" " loco}; do
            mv $file .
        done

        regenie \
        --step 2 \
        ${if is_binary then "--bt --af-cc" else ""} \
        --bgen ${bgen} \
        --ref-first \
        --sample ${sample} \
        --covarFile ${cov_pheno} \
        --covarColList ${covariates} \
        --phenoFile ${cov_pheno} \
        --phenoColList ${sep="," phenolist} \
        --pred ${pred} \
        --bsize ${bsize} \
        --threads $n_cpu \
        --gz \
        --out ${prefix} \
        ${options}

    >>>

    output {
        File log = prefix + ".log"
        Array[File] regenie = glob("*.regenie.gz")
    }

    runtime {
        docker: "${docker}"
        cpu: if length(phenolist) == 1 then 1 else if length(phenolist) <=4 then 2 else if length(phenolist) <= 10 then 4 else if length(phenolist) < 16 then 8 else 16
        memory: if length(phenolist) <= 2 then "4 GB" else "6 GB"
        disks: "local-disk " + (ceil(size(bgen, "G")) + 5) + " HDD"
        zones: "europe-west1-b"
        preemptible: 2
        noAddress: true
    }
}

task gather {

    String pheno
    Boolean is_binary
    Array[File] files

    String docker

    command <<<

        set -euxo pipefail

        echo -e "`date`\tconcatenating result pieces into ${pheno}.regenie.gz, sorting by chr pos just in case"
        cat \
        <(zcat ${files[0]} | head -1) \
        <(for file in ${sep=" " files}; do
            zcat $file | tail -n+2
        done | sort -k1,1g -k2,2g) | bgzip > ${pheno}.regenie.gz

        echo -e "`date`\tconverting to ${pheno}.gz to a format used for importing to pheweb"
        if [[ "${is_binary}" == "true" ]]; then
            zcat ${pheno}.regenie.gz | awk '
            BEGIN {FS=" "; OFS="\t"}
            NR==1 {for(i=1;i<=NF;i++) h[$i]=i; print "#chrom","pos","ref","alt","pval","mlogp","beta","sebeta","af_alt","af_alt_cases","af_alt_controls"}
            NR>1  {print $h["CHROM"],$h["GENPOS"],$h["ALLELE0"],$h["ALLELE1"],10^-$h["LOG10P"],$h["LOG10P"],$h["BETA"],$h["SE"],$h["A1FREQ"],$h["A1FREQ_CASES"],$h["A1FREQ_CONTROLS"]}' \
            | bgzip > ${pheno}.gz
        else
            zcat ${pheno}.regenie.gz | awk '
            BEGIN {FS=" "; OFS="\t"}
            NR==1 {for(i=1;i<=NF;i++) h[$i]=i; print "#chrom","pos","ref","alt","pval","mlogp","beta","sebeta","af_alt"}
            NR>1  {print $h["CHROM"],$h["GENPOS"],$h["ALLELE0"],$h["ALLELE1"],10^-$h["LOG10P"],$h["LOG10P"],$h["BETA"],$h["SE"],$h["A1FREQ"]}' \
            | bgzip > ${pheno}.gz
        fi

        echo -e "`date`\tprinting only chr, pos, pval to speed up and reduce memory use of qqplot.R"
        zcat ${pheno}.gz | cut -f1,2,5 > ${pheno}

        echo -e "`date`\trunning qqplot.R"
        qqplot.R --file ${pheno} --chrcol "#chrom" --bp_col "pos" --pval_col "pval" --loglog_pval 10 > qq_out 2> qq_err

        echo -e "`date`\ttabixing ${pheno}.gz"
        tabix -s1 -b2 -e2 ${pheno}.gz
        echo -e "`date`\tdone"

    >>>

    output {
        File regenie = pheno + ".regenie.gz"
        File pheweb = pheno + ".gz"
        File pheweb_tbi = pheno + ".gz.tbi"
        File qq_out = "qq_out"
        File qq_err = "qq_err"
        Array[File] pngs = glob("*.png")
        Array[File] quantiles = glob("*qquantiles.txt")
    }

    runtime {
        docker: "${docker}"
        cpu: 1
        memory: "6 GB"
        disks: "local-disk 200 HDD"
        zones: "europe-west1-b"
        preemptible: 2
        noAddress: true
    }
}

task summary{

    File input_file
    File finngen_annotation
    File gnomad_annotation
    File finngen_tbi = finngen_annotation + ".tbi"
    File gnomad_tbi = gnomad_annotation + ".tbi"

    Float pval_thresh
    String pheno
    String output_name=pheno+"_summary.txt"
    String docker

    command <<<
        set -euxo pipefail
        python3 <<EOF
        #read file
        fname = "${input_file}"
        finngen_annotation_file = "${finngen_annotation}"
        gnomad_annotation_file  = "${gnomad_annotation}"
        sig_threshold = ${pval_thresh}

        output_name = "${output_name}"

        import pysam
        import gzip
        from typing import NamedTuple

        FGAnnotation = NamedTuple('FGAnnotation',[('gene',str),('consequence',str)])
        GnomadAnnotation = NamedTuple('GnomadAnnotation',[('finaf',str),('nfeaf',str),('rsid',str)])

        def get_header(reader,file):
            with reader(file, "rt") as f:
                l = f.readline()
                return l.strip("\n").split("\t")

        def get_fg_annotation(iterator,variant,gene_idx, consequence_idx,variant_idx) -> FGAnnotation:
            for v in iterator:
                cols = v.strip("\n").split("\t")
                if cols[variant_idx] == variant:
                    return FGAnnotation(cols[gene_idx],cols[consequence_idx])
            return FGAnnotation("","")

        def get_gnomad_annotation(iterator,cpra,finaf_idx, nfeaf_idx, rsid_id,gnomad_cpra) -> GnomadAnnotation:
            for v in iterator:
                cols = v.strip("\n").split("\t")

                if (cols[gd_cpra[0]] == "chr"+cpra[0]) and (cols[gd_cpra[1]] == str(cpra[1])) and (cols[gd_cpra[2]] == cpra[2]) and (cols[gd_cpra[3]] == cpra[3]):
                    return GnomadAnnotation(cols[finaf_idx],cols[nfeaf_idx],cols[rsid_idx])
            return GnomadAnnotation(".",".",".")

        #required columns
        fg_req_cols=["#variant","gene_most_severe","most_severe"]
        gd_req_cols=["fin.AF","nfsee.AF","enrichment_nfsee","rsid"]
        #open finngen annotation tabix
        fg_tabix = pysam.TabixFile(finngen_annotation_file,parser=None)
        #get fg header column positions
        fg_header = get_header(gzip.open, finngen_annotation_file)
        fg_idx = {v:i for (i,v) in enumerate(fg_header)}
        #open gnomad annotation tabix
        gnomad_tabix = pysam.TabixFile(gnomad_annotation_file,parser=None)
        gd_header = get_header(gzip.open, gnomad_annotation_file)
        gd_idx = {v:i for (i,v) in enumerate(gd_header)}
        gd_cpra = (
            gd_idx["chrom"],
            gd_idx["pos"],
            gd_idx["ref"],
            gd_idx["alt"]
        )
        #check for fg column existence
        if not all([a in fg_header for a in fg_req_cols]):
            raise Exception("Not all columns present in FinnGen annotation! Aborting...")
        #check for gnomad column existence
        if not all([a in gd_header for a in gd_req_cols]):
            raise Exception("Not all columns present in Gnomad annotation! Aborting...")
        var_idx, gene_idx, cons_idx = (fg_idx["#variant"],fg_idx["gene_most_severe"],fg_idx["most_severe"])

        finaf_idx, nfeaf_idx, rsid_idx = (gd_idx["fin.AF"],gd_idx["nfsee.AF"],gd_idx["rsid"])



        with gzip.open(fname, "rt") as file:
            #open output file
            with open(output_name,"w") as outfile:
                #read header
                header = file.readline().strip("\n").split('\t')
                #find p-value index
                header_idx = {v:i for (i,v) in enumerate(header)}
                pval_idx = header_idx["pval"]
                cid,pid,rid,aid = (
                    header_idx["#chrom"],
                    header_idx["pos"],
                    header_idx["ref"],
                    header_idx["alt"]
                )

                #add gene name, consequence, gnomad finnish af, nfsee af, rsid
                header.extend(["fin.AF","nfsee.AF","rsid","gene_most_severe","most_severe"])
                outfile.write("\t".join(header)+"\n")
                #read lines
                for line in file:
                    line_columns = line.strip("\n").split('\t')
                    pvalue = float(line_columns[pval_idx])
                    if pvalue < sig_threshold:
                        cpra= (line_columns[cid],int(float(line_columns[pid])),line_columns[rid],line_columns[aid])
                        variant = "{}:{}:{}:{}".format(cpra[0],cpra[1],cpra[2],cpra[3])
                        fg_c = cpra[0].replace("chr","").replace("X","23").replace("Y","24").replace("M","25").replace("MT","25")
                        gd_c = "chr" + cpra[0].replace("chr","").replace("23","X").replace("24","Y").replace("25","M")
                        #annotate
                        fg_iter = fg_tabix.fetch(fg_c,cpra[1]-1, cpra[1])
                        fg_a = get_fg_annotation(fg_iter,variant, gene_idx,cons_idx,var_idx)

                        #annotate
                        gnomad_iter = gnomad_tabix.fetch(gd_c,cpra[1]-1, cpra[1])
                        gd_a = get_gnomad_annotation(gnomad_iter,cpra,finaf_idx, nfeaf_idx, rsid_idx,gd_cpra)

                        line_columns.extend([
                            gd_a.finaf,
                            gd_a.nfeaf,
                            gd_a.rsid,
                            fg_a.gene,
                            fg_a.consequence,
                        ])
                        #gather row
                        #write to file
                        outfile.write("\t".join(line_columns)+"\n")
        print("summary created")
        EOF

    >>>

    output {
        File out = output_name
    }

    runtime {
        docker: "${docker}"
        cpu: 1
        memory: "2 GB"
        disks: "local-disk 200 HDD"
        zones: "europe-west1-b"
        preemptible: 2
    }
}

workflow regenie_step2 {

    String docker
    Array[String] phenolist
    Boolean is_binary
    String cov_pheno
    String covariates

    String pred
    Array[String] loco

    File bgenlist
    Array[String] bgens = read_lines(bgenlist)

    scatter (bgen in bgens) {
        call step2 {
            input: docker=docker, phenolist=phenolist, is_binary=is_binary, cov_pheno=cov_pheno, covariates=covariates, pred=pred, loco=loco, bgen=bgen
        }
    }

    Array[Array[String]] pheno_results = transpose(step2.regenie)
    scatter (i in range(length(phenolist))) {
        call gather {
            input: pheno=phenolist[i], is_binary=is_binary, files=pheno_results[i]
        }
        call summary {
            input: pheno=phenolist[i], input_file=gather.pheweb
        }
    }

    output {
        Array[File] pheweb = gather.pheweb
        Array[File] pheweb_tbi = gather.pheweb_tbi
        Array[File] qq_out = gather.qq_out
        Array[File] qq_err = gather.qq_err
        Array[Array[File]] pngs = gather.pngs
        Array[Array[File]] quantiles = gather.quantiles
        Array[File] summary = summary.out
    }
}