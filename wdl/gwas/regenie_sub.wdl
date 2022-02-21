task step2 {

    Array[String] phenolist
    File cov_pheno
    String covariates
    String test
    # regenie accepts either no test specified (i.e. additive), or '--test dominant' or '--test recessive'. '--test additive' is an error.
    String test_cmd = if test == "additive" then "" else "--test "+ test
    Boolean is_binary
    File bgen
    File bgi = bgen + ".bgi"
    File sample = bgen + ".sample"
    File pred
    File firth_list
    String prefix = sub(basename(pred), "_pred.list", "") + "." + basename(bgen)
    Array[File] loco
    Array[File] nulls
    Int bsize
    String options

    String docker


    Float sex_specific_logpval
    String sex_col_name
    Boolean run_sex_specific

    String DOLLAR="$"

    command <<<
        echo '''BEGIN{print_males ="males";print_females="females";males[0]=0;males[1]=0;females[0]=0;females[1]=0}
NR==1{ for(i=1;i<=NF;i++) {h[$i]=i}}
NR>1{
if($h[sexcol]==0 && $h[phenocol]!="NA"){males[$h[phenocol]] += 1 }
if($h[sexcol]==1 && $h[phenocol]!="NA"){females[$h[phenocol]] += 1}}
END{
if(males[0]<10 ||males[1]<10){print_males = "";print "Skipping male sex-specific analysis: phenotype",phenocol,"had only",males[0] ",", males[1], "male controls/cases." > "/dev/stderr"}
if(females[0]<10 ||females[1]<10){print_females = "";print "Skipping female sex-specific analysis: phenotype",phenocol,"had only",females[0] ",", females[1], "female controls/cases." > "/dev/stderr"}
print print_males,print_females
}
''' > filter_sex_spec_analysis.awk
        ## continue statement exits with 1.... switch to if statement below in case want to pipefail back
        ##set -euxo pipefail

        n_cpu=`grep -c ^processor /proc/cpuinfo`

        # move loco files to /cromwell_root as pred file paths point there
        for file in ${sep=" " loco}; do
            mv $file .
        done

        # move null files to /cromwell_root as firth_list file paths point there
        for file in ${sep=" " nulls}; do
            mv $file .
        done

        regenie \
        --step 2 \
        ${test_cmd} \
        ${if is_binary then "--bt --af-cc" else ""} \
        --bgen ${bgen} \
        --ref-first \
        --sample ${sample} \
        --covarFile ${cov_pheno} \
        --covarColList ${covariates} \
        --phenoFile ${cov_pheno} \
        --phenoColList ${sep="," phenolist} \
        --pred ${pred} \
        ${if is_binary then "--use-null-firth ${firth_list}" else ""} \
        --bsize ${bsize} \
        --threads $n_cpu \
        --gz \
        --out ${prefix} \
        ${options}


        if [[ "${run_sex_specific}" == "true" ]];
        then
          zcat ${cov_pheno} | awk 'NR==1{ for(i=1;i<=NF;i++) {h[$i]=i};
                                             if(!("${sex_col_name}" in h)) {
                                                print "Given sex column not found in phenotype file" > "/dev/stderr";
                                                exit 1;
                                              }
                                        }
                                  NR>1&&$h["${sex_col_name}"]==0{ print $1,$1}' > males

          zcat ${cov_pheno} | awk 'NR==1{  for(i=1;i<=NF;i++) {h[$i]=i };
                                          if(!("${sex_col_name}" in h))
                                          {
                                            print "Given sex column not found in phenotype file" > "/dev/stderr";
                                            exit 1;
                                          }
                                       }
                                  NR>1&&$h["${sex_col_name}"]==1{ print $1,$1}' > females

          sex_covars=$(echo ${covariates} | sed -e 's/${sex_col_name}//' | sed 's/^,//' | sed -e 's/,$//' | sed 's/,,/,/g')

          if [[ $sex_covars == ${covariates} ]];
          then
            echo "Warning! No sex covariate detected in used covariates."
          fi

          for p in ${sep=" " phenolist}; do

            base=${prefix}"_"$p".regenie.gz"

            zcat $base | awk 'NR==1{ for(i=1;i<=NF;i++) { h[$i]=i };
                                     if(!("ID" in h )||!("LOG10P" in h))
                                     {
                                       print "ID and LOG10P columns expected in association file" >"/dev/stderr"; exit 1}
                                     }
                             NR>1&&$h["LOG10P"]>${sex_specific_logpval} { print $h["ID"]} ' > $p".sex_variants"

            nvars=$(cat $p".sex_variants"| wc -l  )

            echo "$nvars will be tested for sex specific effects"

            if [[ $nvars -lt 1 ]];
            then
              ## NOTE
              ## NOTE: Echoing annoyingly the expected header here so that in gather the header can be taken from the first shard.
              ## NOTE This must match whats written from python below
              echo -n "CHROM GENPOS ID ALLELE0 ALLELE1 A1FREQ A1FREQ_CASES A1FREQ_CONTROLS INFO N TEST BETA SE CHISQ LOG10P"\
              "males_ID males_A1FREQ_CASES males_A1FREQ_CONTROLS males_N males_BETA males_SE males_LOG10P"\
              "females_ID females_A1FREQ_CASES females_A1FREQ_CONTROLS females_N females_BETA females_SE females_LOG10P"\
              "diff_beta p_diff" | bgzip > ${prefix}"."$p".sex_spec.gz"
              continue
            fi

            # NOTE
            # NOTE figure out whether we can run males and or females sex-specific analysis. In some endpoints, there are too little 
            # NOTE cases (under 10) per sex, which errors out the script.
            sex_analyses=$(zcat ${cov_pheno} | awk -v phenocol=$p -v sexcol=${sex_col_name} -f filter_sex_spec_analysis.awk)

            for s in $sex_analyses;
            do
              echo "running $s analysis"
              echo "$(wc -l $s) individuals in file"
              head $s

              regenie \
              --step 2 \
              ${test_cmd} \
              ${if is_binary then "--bt --af-cc" else ""} \
              --bgen ${bgen} \
              --ref-first \
              --sample ${sample} \
              --keep $s  \
              --extract $p".sex_variants" \
              --covarFile ${cov_pheno} \
              --covarColList $sex_covars \
              --phenoFile ${cov_pheno} \
              --phenoColList $p \
              --pred ${pred} \
              --bsize ${bsize} \
              --threads $n_cpu \
              --gz \
              --out ${prefix}".sex_spec."$s \
              ${options}
            done

            echo "all files"
            ls *

            for f in $(ls *".sex_spec."*.regenie.gz ); do
              to=${DOLLAR}{f/%.regenie.gz/.gz}
              mv $f $to
              echo "file" $to
            done

echo '''import pandas as pd
import gzip
import sys
import math
from scipy.stats import norm
import numpy as np

pheno=sys.argv[1]
prefix=sys.argv[2]
base=sys.argv[3]

male=prefix+ ".sex_spec.males_" + pheno + ".gz"
female=prefix+".sex_spec.females_" + pheno + ".gz"


## NOTE:  See above where Echoing the expected header in case no sex specific results (above continue statement) and we want each shard to
## NOTE: have correct header so in gather step the first line of first file can serve as a header.
## NOTE: IF changing output columns in here, change the columns accordingly above.
basic_cols = ["CHROM","GENPOS","ID","ALLELE0","ALLELE1","A1FREQ", "A1FREQ_CASES", "A1FREQ_CONTROLS", "INFO", "N", "TEST", "BETA","SE","CHISQ","LOG10P"]
sex_cols = ["ID","A1FREQ_CASES","A1FREQ_CONTROLS","N","BETA","SE","LOG10P"]

basic = pd.read_csv( gzip.open(base), sep=" ")[basic_cols]

malestat = pd.read_csv( gzip.open( male ), sep=" " )[sex_cols]
femalestat = pd.read_csv( gzip.open(female), sep=" ")[sex_cols]
combs = basic.merge(malestat.add_prefix("males_"),
          left_on="ID",right_on="males_ID").merge(femalestat.add_prefix("females_"),left_on="ID", right_on="females_ID")

combs["diff_beta"] = combs["males_BETA"]-combs["females_BETA"]
print(combs)
print(combs.dtypes)
if(len(combs.index))>0:
  combs["p_diff"] = -((norm.logsf( abs(combs["diff_beta"])/( np.sqrt(combs["males_SE"]**2+combs["females_SE"]**2))) + math.log(2) ) / math.log(10))
else:
  combs["p_diff"]=0

combs.to_csv(prefix+"."+pheno+".sex_spec.gz", compression="gzip", sep=" ", index=False)

''' > source.py
          python3 source.py $p ${prefix} ${prefix}"_"$p".regenie.gz"
          done
        else
          ## sex specific analyses disabled but create the file so gather step is straightforward to implement
          touch ${prefix}"NOT_DONE.sex_spec.gz"
        fi

    >>>

    output {
        Array[File] log = glob("*.log")
        Array[File] regenie = glob("*.regenie.gz")
        Array[File] sex_specifix = glob("*.sex_spec.gz")
    }

    runtime {
        docker: "${docker}"
        cpu: if length(phenolist) == 1 then 1 else if length(phenolist) <=4 then 2 else if length(phenolist) <= 10 then 4 else if length(phenolist) < 16 then 8 else 16
        memory: if length(phenolist) <= 2 then "4 GB" else "6 GB"
        disks: "local-disk " + (ceil(size(bgen, "G")) + 5) + " HDD"
        zones: "europe-west1-b europe-west1-c europe-west1-d"
        preemptible: 2
        noAddress: true
    }
}

task gather {

    Boolean is_binary
    Array[File] files

    Array[File] sex_files

    String docker

    command <<<

        set -euxo pipefail

        pheno=`basename ${files[0]} .regenie.gz | awk -F "." '{sub(/[^_]*_/, "", $NF); print $NF}'`
        mkdir regenie munged

        echo -e "`date`\tconcatenating result pieces into regenie/$pheno.regenie.gz, sorting by chr pos just in case"
        cat \
        <(zcat ${files[0]} | head -1) \
        <(for file in ${sep=" " files}; do
            zcat $file | tail -n+2
        done | sort -k1,1g -k2,2g) | bgzip > regenie/$pheno.regenie.gz


        if [[ ${length(sex_files)} -ge 1 ]]; then
          echo "concatenating sex diff results into regenie/$pheno.regenie.sex_diff.gz"
        cat \
        <(zcat ${sex_files[0]} | awk '{ print "#"$0; exit 0}') \
        <(for file in ${sep=" " sex_files}; do
            zcat $file | tail -n+2
        done | sort -k1,1g -k2,2g) | tr ' ' '\t' | bgzip > regenie/$pheno.regenie.sex_diff.gz
        tabix -s 1 -b 2 -e 2 regenie/$pheno.regenie.sex_diff.gz
        else
          touch regenie/$pheno.regenie.sex_diff.gz
          touch regenie/$pheno.regenie.sex_diff.gz.tbi
        fi

        if [[ "${is_binary}" == "true" ]]; then
            echo -e "`date`\tconverting to munged/$pheno.gz to a format used for importing to pheweb, omitting variants with -log10p NA (unsuccessful Firth/SPA)"
            zcat regenie/$pheno.regenie.gz | awk '
            BEGIN {FS=" "; OFS="\t"; split("CHROM GENPOS ALLELE0 ALLELE1 LOG10P BETA SE A1FREQ A1FREQ_CASES A1FREQ_CONTROLS", REQUIRED_FIELDS)}
            NR==1 {for(i=1;i<=NF;i++) h[$i]=i;
                   for(i in REQUIRED_FIELDS) if (!(REQUIRED_FIELDS[i] in h)) {print REQUIRED_FIELDS[i]" expected in regenie header">>"/dev/stderr"; exit 1}
                   print "#chrom","pos","ref","alt","pval","mlogp","beta","sebeta","af_alt","af_alt_cases","af_alt_controls"}
            NR>1 && $h["LOG10P"]!="NA" {print $h["CHROM"],$h["GENPOS"],$h["ALLELE0"],$h["ALLELE1"],10^-$h["LOG10P"],$h["LOG10P"],$h["BETA"],$h["SE"],$h["A1FREQ"],$h["A1FREQ_CASES"],$h["A1FREQ_CONTROLS"]}' \
            | bgzip > munged/$pheno.gz
        else
            echo -e "`date`\tconverting to munged/$pheno.gz to a format used for importing to pheweb"
            zcat regenie/$pheno.regenie.gz | awk '
            BEGIN {FS=" "; OFS="\t"; split("CHROM GENPOS ALLELE0 ALLELE1 LOG10P BETA SE A1FREQ", REQUIRED_FIELDS)}
            NR==1 {for(i=1;i<=NF;i++) h[$i]=i;
                   for(i in REQUIRED_FIELDS) if (!(REQUIRED_FIELDS[i] in h)) {print REQUIRED_FIELDS[i]" expected in regenie header">>"/dev/stderr"; exit 1}
                   print "#chrom","pos","ref","alt","pval","mlogp","beta","sebeta","af_alt"}
            NR>1  {print $h["CHROM"],$h["GENPOS"],$h["ALLELE0"],$h["ALLELE1"],10^-$h["LOG10P"],$h["LOG10P"],$h["BETA"],$h["SE"],$h["A1FREQ"]}' \
            | bgzip > munged/$pheno.gz
        fi

        echo -e "`date`\tprinting only chr, pos, pval to speed up and reduce memory use of qqplot.R"
        ## added SNP as updated manhattan function from qqman package fails without it.
        zcat munged/$pheno.gz | cut -f1,2,5 | awk 'BEGIN{ FS=OFS="\t"} NR==1{ print $0,"SNP"} NR>1{ print $0,NR}' > $pheno

        head $pheno

        echo -e "`date`\trunning qqplot.R"
        qqplot.R --file $pheno --chrcol "#chrom" --bp_col "pos" --pval_col "pval" --loglog_pval 10 > qq_out 2> qq_err

        echo -e "`date`\ttabixing munged/$pheno.gz"
        tabix -s1 -b2 -e2 munged/$pheno.gz
        echo -e "`date`\tdone"

    >>>

    output {
        File regenie = glob("regenie/*.regenie.gz")[0]
        File regenie_sex_diff = glob("regenie/*.regenie.sex_diff.gz")[0]
        File regenie_sex_diff_tbi = glob("regenie/*.regenie.sex_diff.gz.tbi")[0]
        File pheweb = glob("munged/*.gz")[0]
        File pheweb_tbi = glob("munged/*.gz.tbi")[0]
        File qq_out = "qq_out"
        File qq_err = "qq_err"
        Array[File] pngs = glob("*.png")
        Array[File] quantiles = glob("*qquantiles.txt")
    }

    runtime {
        docker: "${docker}"
        cpu: 1
        memory: "8 GB"
        disks: "local-disk 200 HDD"
        zones: "europe-west1-b europe-west1-c europe-west1-d"
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

    Float summary_pval_thresh
    Float coding_pval_thresh
    String docker

    command <<<
        set -euxo pipefail
        python3 <<EOF
        #read file
        fname = "${input_file}"
        finngen_annotation_file = "${finngen_annotation}"
        gnomad_annotation_file  = "${gnomad_annotation}"
        summary_threshold = ${summary_pval_thresh}
        coding_threshold = ${coding_pval_thresh}

        import pysam
        import gzip
        import os
        from typing import NamedTuple

        coding_groups = set([
            "transcript_ablation",
            "splice_donor_variant",
            "stop_gained",
            "splice_acceptor_variant",
            "frameshift_variant",
            "stop_lost",
            "start_lost",
            "inframe_insertion",
            "inframe_deletion",
            "missense_variant",
            "protein_altering_variant"
        ])

        pheno = os.path.splitext(os.path.basename(fname))[0]
        output_summary_name = pheno + "_summary.txt"
        output_coding_name = pheno + "_coding.txt"
        FGAnnotation = NamedTuple('FGAnnotation',[('gene',str),('consequence',str)])
        GnomadAnnotation = NamedTuple('GnomadAnnotation',[('finaf',str),('nfeaf',str),('enrich',str),('rsid',str)])

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

        def get_gnomad_annotation(iterator,cpra,finaf_idx, nfeaf_idx, rsid_idx,gd_cpra) -> GnomadAnnotation:
            for v in iterator:
                cols = v.strip("\n").split("\t")

                if (cols[gd_cpra[0]] == "chr"+cpra[0]) and (cols[gd_cpra[1]] == str(cpra[1])) and (cols[gd_cpra[2]] == cpra[2]) and (cols[gd_cpra[3]] == cpra[3]):
                    return GnomadAnnotation(cols[finaf_idx],cols[nfeaf_idx],cols[enrich_idx],cols[rsid_idx])
            return GnomadAnnotation(".",".",".",".")

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

        finaf_idx, nfeaf_idx, enrich_idx, rsid_idx = (gd_idx["fin.AF"],gd_idx["nfsee.AF"],gd_idx["enrichment_nfsee"],gd_idx["rsid"])



        with gzip.open(fname, "rt") as file:
            #open output file
            with open(output_summary_name,"w") as summary_outfile, open(output_coding_name,"w") as coding_outfile:
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
                summary_outfile.write("\t".join(header)+"\n")
                #add pheno, fin enrichment
                header.extend(["fin.enrichment","phenotype"])
                coding_outfile.write("\t".join(header)+"\n")

                #read lines
                for line in file:
                    line_columns = line.strip("\n").split('\t')
                    pvalue = float(line_columns[pval_idx])
                    if pvalue < coding_threshold or pvalue < summary_threshold:
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
                        if pvalue < summary_threshold:
                            summary_outfile.write("\t".join(line_columns)+"\n")

                        #coding out
                        if pvalue < coding_threshold and fg_a.consequence in coding_groups:
                            line_columns.extend([
                                gd_a.enrich,
                                pheno
                            ])
                            coding_outfile.write("\t".join(line_columns)+"\n")
        print("summary created")
        EOF

    >>>

    output {
        File summary_out = glob("*_summary.txt")[0]
        File coding_out = glob("*_coding.txt")[0]
    }

    runtime {
        docker: "${docker}"
        cpu: 1
        memory: "2 GB"
        disks: "local-disk 200 HDD"
        zones: "europe-west1-b europe-west1-c europe-west1-d"
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
    String firth_list
    Array[String] nulls

    File bgenlist
    Array[String] bgens = read_lines(bgenlist)

    String sex_col_name

    Boolean is_single_sex
    Boolean run_sex_specific

    scatter (bgen in bgens) {
        call step2 {
            input: docker=docker, phenolist=phenolist, is_binary=is_binary, cov_pheno=cov_pheno,
              covariates=covariates, pred=pred, loco=loco, nulls=nulls,firth_list=firth_list,bgen=bgen,
              sex_col_name=sex_col_name, run_sex_specific=(run_sex_specific && !is_single_sex)
        }
    }

    Array[Array[String]] pheno_results = transpose(step2.regenie)

    Array[Array[String]] pheno_results_sex = transpose(step2.sex_specifix)

    scatter (pheno_result_idx in range(length(pheno_results))) {
        call gather {
            input: is_binary=is_binary, files=pheno_results[pheno_result_idx],
              sex_files = pheno_results_sex[pheno_result_idx], docker=docker
        }
        call summary {
            input: input_file=gather.pheweb, docker=docker
        }
    }

    output {
        Array[File] pheweb = gather.pheweb
        Array[File] pheweb_tbi = gather.pheweb_tbi
        Array[File] qq_out = gather.qq_out
        Array[File] qq_err = gather.qq_err
        Array[Array[File]] pngs = gather.pngs
        Array[Array[File]] quantiles = gather.quantiles
        Array[File] summary = summary.summary_out
        Array[File] coding = summary.coding_out
    }
}
