#!/bin/bash
set -e

# machine configuration
NUMBER_PROCESSORS=32
MEMORY_LIMIT=40GB

# remote source for reference genome
REFERENCE_FASTA_SOURCE_SERVER=ftp://ftp.1000genomes.ebi.ac.uk
REFERENCE_FASTA_SOURCE_DIR=vol1/ftp/technical/reference/phase2_reference_assembly_sequence
REFERENCE_FASTA_SOURCE_NAME=hs37d5.fa.gz
REFERENCE_FASTA_SOURCE="$REFERENCE_FASTA_SOURCE_SERVER/$REFERENCE_FASTA_SOURCE_DIR/$REFERENCE_FASTA_SOURCE_NAME"

# local reference genome location
REFERENCE_DIR=.
REFERENCE_FASTA_NAME="hs37d5.fasta"
REFERENCE_FASTA_PATH="$REFERENCE_DIR/$REFERENCE_FASTA_NAME"
REFERENCE_INDEX_PATH="$REFERENCE_FASTA_PATH.bwt"

echo "Simple somatic variant calling pipeline";
echo "=======";

if [ $# -ne 4 ] ; then
    echo "Wrong number of arguments ($#)";
    echo "Expected arguments:";
    echo "      (1) directory containing normal FASTQ files";
    echo "      (2) common prefix in names of all normal FASTQ files";
    echo "      (3) directory containing tumor FASTQ files";
    echo "      (4) common prefix in names of all tumor FASTQ files";
    echo "----"
    echo "Example:";
    echo "      ./call-somatic-variants.sh . normal . tumor";
    exit 1;
else
    NORMAL_FASTQ_DIR=$1;
    NORMAL_FASTQ_PREFIX=$2;
    TUMOR_FASTQ_DIR=$3;
    TUMOR_FASTQ_PREFIX=$4;
fi

echo "Quick & Dirty Somatic Variant Calling Pipeline";
echo "---";
echo "Normal FASTQ location: $NORMAL_FASTQ_DIR/$NORMAL_FASTQ_PREFIX*.fastq";
echo "Tumor FASTQ location: $TUMOR_FASTQ_DIR/$TUMOR_FASTQ_PREFIX*.fastq";
echo "---";


function run() {
        # print a command before running it wrapped in a 'time' command
        local COMMAND=$1;
        echo $COMMAND;
        eval "time $COMMAND"
}

function download_and_index_reference_genome() {
        echo "-- download_and_index_reference_genome";
        if [ ! -e $REFERENCE_FASTA_PATH ]; then
                echo "Couldn't find reference file $REFERENCE_FASTA_PATH";
                echo "Downloading from $REFERENCE_FASTA_SOURCE..."
                run "wget $REFERENCE_FASTA_SOURCE";
                echo "Decompressing downloaded reference genome..."
                run "gunzip hs37d5.fa.gz";
                run "mv hs37d5.fa $REFERENCE_FASTA_PATH";
        else
                echo "Using reference: $REFERENCE_FASTA_PATH"
        fi;
        if [ ! -s $REFERENCE_INDEX_PATH ]; then
                echo "Creating index for $REFERENCE_FASTA_PATH"
                run "bwa index $REFERENCE_FASTA_PATH";
        fi;
}


function align_fastq_pairs() {
        # Align every FASTQ pair into multiple BAM files
        local FASTQ_DIR=$1;
        local FASTQ_PREFIX=$2;

        echo "-- align_fastq_pairs";
        echo "  FASTQ_DIR=$FASTQ_DIR";
        echo "  FASTQ_PREFIX=$FASTQ_PREFIX";

        if [ $# -ne 2 ] ; then
            echo "Expected 2 arguments but got $#";
            exit 1;
        fi

        # check to make sure that all arguments are non-empty
        if [[ -z $FASTQ_DIR ]] ; then
                echo "Missing first argument (FASTQ_DIR)";
                exit 1;
        fi
        if [[ -z $FASTQ_PREFIX ]] ; then
                echo "Missing second argument (FASTQ_PREFIX)";
                exit 1;
        fi

        for R1_fastq in $FASTQ_DIR/$FASTQ_PREFIX*.R1.fastq.gz ; do
                R2_fastq=`echo $R1_fastq | sed -e 's/\.R1\./\.R2\./g'`
                if [ ! -e $R2_fastq ]; then
                        echo "Couldn't find R2 ($R2_fastq) corresponding to $R1_fastq"
                        exit 1;
                fi;
                echo "R1: $R1_fastq";
                echo "R2: $R2_fastq";
                # make a local file name for the BAM we're going to generate from each FASTQ pair
                local READ_GROUP=`basename $R1_fastq | sed -e 's/\.R1\.fastq\.gz//g'`
                local BAM="$READ_GROUP.bam"
                # test if $BAM exists and is non-empty
                if [  -s $BAM ]; then
                    echo "Skipping alignment of $R1_fastq and $R2_fastq since $BAM already exists"
                else
                    echo "Generating BAM file $BAM";
                    local READ_GROUP_TAG="'@RG\tID:$READ_GROUP\tSM:$FASTQ_PREFIX\tLB:$FASTQ_PREFIX\tPL:ILLUMINA'"
                    run "bwa mem -M \
                            -t $NUMBER_PROCESSORS \
                            -R $READ_GROUP_TAG \
                            $REFERENCE_FASTA_PATH \
                            $R1_fastq \
                            $R2_fastq \
                            | samtools view -S -b -@$NUMBER_PROCESSORS -o $BAM -";
                    echo "---";
                fi;
        done
}

function process_alignments() {
        # Runs the following pipeline steps:
        #       - sort BAM
        #       - index BAM
        #       - mark duplicates
        # Input: sample bam (expected to exist $SAMPLE_NAME.bam)
        # Output: generates SAMPLE_NAME.final.bam

        local UNSORTED_BAM_PREFIX=$1;
        echo "-- process_alignments";
        echo "  UNSORTED_BAM_PREFIX: $UNSORTED_BAM_PREFIX";

        if [ $# -ne 1 ] ; then
            echo "Expected 1 argument but got $#";
            exit 1;
        fi

        # sort and index every BAM
        # for any name X.bam, create X.sorted.bam
        # exclude file names which contain sequence '.sorted.'
        for UNSORTED_BAM in $UNSORTED_BAM_PREFIX*.bam ; do
            case $UNSORTED_BAM in
                *.sorted.*)
                    echo "Skipping $UNSORTED_BAM since it contains '.sorted.'";
                    continue;;
                *.merged.*)
                    echo "Skipping $UNSORTED_BAM since it contains '.merged.'";
                    continue;;
                *.final.*)
                    echo "Skipping $UNSORTED_BAM since it contains '.final.'";
                    continue;;
                *)
                    local SORTED_BAM=`echo $UNSORTED_BAM | sed -e 's/\.bam/\.sorted\.bam/g'`
                    if [ -s $SORTED_BAM ]; then
                        echo "Skipping sorting for $UNSORTED_BAM since $SORTED_BAM already exists";
                    else
                        echo "Sorting $UNSORTED_BAM to generate $SORTED_BAM";
                        run "sambamba sort \
                                --memory-limit $MEMORY_LIMIT \
                                --show-progress \
                                --nthreads $NUMBER_PROCESSORS \
                                --out $SORTED_BAM \
                                $UNSORTED_BAM";
                    fi
                    local SORTED_BAM_INDEX="$SORTED_BAM.bai"
                    if [ -s $SORTED_BAM_INDEX ]; then
                        echo "Skipping indexing for $SORTED_BAM since $SORTED_BAM_INDEX already exists"
                    else
                        echo "Indexing sorted BAM $SORTED_BAM";
                        run "sambamba index \
                            --nthreads $NUMBER_PROCESSORS \
                            --show-progress \
                            $SORTED_BAM";
                    fi
            esac
        done
        local MERGED_BAM="$UNSORTED_BAM_PREFIX.merged.bam"
        if [ -s $MERGED_BAM ]; then
            echo "Skipping merge since $MERGED_BAM already exists"
        else
            run "sambamba merge \
                --nthreads $NUMBER_PROCESSORS \
                --show-progress \
                $MERGED_BAM \
                $UNSORTED_BAM_PREFIX*.sorted.bam";
        fi
        local FINAL_BAM="$UNSORTED_BAM_PREFIX.final.bam";
        if [ -s $FINAL_BAM ]; then
            echo "Skipping markdup since $FINAL_BAM already exists"
        else
            echo "Marking duplicates to generate $FINAL_BAM";
            # for larger WGS, need to have both larger overflow
            # list and hash table to avoid hitting too many open
            # files
            run "sambamba markdup \
                    --nthreads $NUMBER_PROCESSORS \
                    --show-progress \
                    --overflow-list-size 1000000 \
                    --hash-table-size 4194304 \
                    $MERGED_BAM \
                    $FINAL_BAM";
        fi
        local FINAL_BAM_INDEX="$FINAL_BAM.bai"
        if [ -s $FINAL_BAM_INDEX ]; then
            echo "Skipping indexing on $FINAL_BAM since $FINAL_BAM_INDEX already exists"
        else
            echo "Indexing final BAM";
            run "sambamba index \
                    --nthreads $NUMBER_PROCESSORS \
                    --show-progress \
                    $FINAL_BAM";
        fi
}


function call_somatic_variants() {
        local NORMAL_BAM=$1;
        local TUMOR_BAM=$2;
        echo "-- call_somatic_variants";
        echo "  NORMAL_BAM: $NORMAL_BAM";
        echo "  TUMOR_BAM: $TUMOR_BAM";

        if [ $# -ne 2 ] ; then
            echo "Expected 2 argument but got $#";
            exit 1;
        fi

        echo "Generating Strelka2 configuration";
        run "configureStrelkaSomaticWorkflow.py \
                --normalBam $NORMAL_BAM \
                --tumorBam $TUMOR_BAM \
                --referenceFasta $REFERENCE_FASTA_PATH \
                --runDir .";
        echo "Running Strelka2";
        # execution on a single local machine with 20 parallel jobs
        run "./runWorkflow.py -m local -j $NUMBER_PROCESSORS";
}

download_and_index_reference_genome;
align_fastq_pairs $NORMAL_FASTQ_DIR $NORMAL_FASTQ_PREFIX;
align_fastq_pairs $TUMOR_FASTQ_DIR $TUMOR_FASTQ_PREFIX;
process_alignments $NORMAL_FASTQ_PREFIX;
process_alignments $TUMOR_FASTQ_PREFIX;
call_somatic_variants "$NORMAL_FASTQ_PREFIX.final.bam" "$TUMOR_FASTQ_PREFIX.final.bam";
