#!/usr/bin/env bash

# bash config
set -e
set -u
set -o pipefail
# set -x # verbose

# general config
# NOTE: modify KALDI_ROOT in path.sh
. ./path.sh
. ./cmd.sh

chime5_dir=$KALDI_ROOT/egs/chime5/s5
exp_dir=$KALDI_ROOT/egs/chime5/s5/exp
recog_set="dev_worn"
model_dir="./model"

# decoding config
min_active=200
max_active=700
max_mem=50000000
beam=15.0
lattice_beam=8.0
acwt=1.0
chain_dir=$exp_dir/chain_train_worn_u100k_cleaned
graphdir=$chain_dir/tree_sp/graph
# TODO use final.mdl
trans_model=$chain_dir/tdnn1a_sp/0.mdl
scoring_opts="--min-lmwt 4 --max-lmwt 15 --word_ins_penalty 0.0,0.5,1.0"

# exp config
stage=0

. ./parse_options.sh || exit 1;

ln -sf $chime5_dir/utils .

if [ -d $chain_dir/tdnn1a_sp/egs/cegs1.ark ]; then
    echo "cegs*.ark not found. use local/chain/run_tdnn.sh --remove-egs false"
fi

if [ -d $trans_model ]; then
    echo "$trans_model is not found"
    exit 1;
fi

mkdir -p $model_dir

# TODO support multi GPU
if [ $stage -le 1 ]; then
    echo "=== stage 1: acoustic model training ==="
    ${train_cmd} $model_dir/log/train.log python train.py \
           --exp_dir $exp_dir \
           --model_dir $model_dir
fi

nj=20


# TODO merge stage 2 and 3 with pipe and remove forward/dev_worn_split.JOB.ark
if [ $stage -le 2 ]; then
    echo "=== stage 2: calc acoustic log-likelihood ==="
    mkdir -p $model_dir/forward
    for label in $recog_set; do
        aux_dir=$exp_dir/nnet3_train_worn_u100k_cleaned/ivectors_${label}_hires
        input_dir=$exp_dir/../data/${recog_set}_hires/split$nj

        ${decode_cmd} \
            JOB=1:$nj $model_dir/log/forward.JOB.log \
            python forward.py \
            --aux_scp $aux_dir/ivector_online.scp \
            --input_rs "ark,s,cs:apply-cmvn --norm-means=false --norm-vars=false --utt2spk=ark:${input_dir}/JOB/utt2spk scp:${input_dir}/JOB/cmvn.scp scp:${input_dir}/JOB/feats.scp ark:- |" \
            --model_dir $model_dir \
            --forward_ark $model_dir/forward/${label}_split.JOB.ark
    done
fi


# TODO search decoding params
if [ $stage -le 3 ]; then
    echo "=== stage 3: decoding ==="
    for label in $recog_set; do
        decode_dir=$model_dir/decode/${label}
        mkdir -p $decode_dir
        ${decode_cmd} \
            JOB=1:$nj $model_dir/log/decode.JOB.log \
            latgen-faster-mapped \
            --min-active=$min_active --max-active=$max_active \
            --max-mem=$max_mem --beam=$beam \
            --lattice-beam=$lattice_beam --acoustic-scale=$acwt \
            --allow-partial=true --word-symbol-table=$graphdir/words.txt \
            $trans_model $graphdir/HCLG.fst \
            ark:$model_dir/forward/${label}_split.JOB.ark \
            "ark:|gzip -c > ${decode_dir}/lat.JOB.gz" || exit 1;
    done
fi

# TODO evaluation
if [ $stage -le 4 ]; then
    echo "=== stage 4: evaluation ==="
    # see compute_wer.sh in chime5
    for label in $recog_set; do
        decode_dir=$model_dir/decode/${label}
        data_dir=$chime5_dir/data/$label
        $chime5_dir/local/score.sh $scoring_opts --cmd "${decode_cmd}" $data_dir $graphdir $decode_dir || exit 1;
    done
fi
# nnet3-latgen-faster-parallel --num-threads=4 --online-ivectors=scp:exp/nnet3_train_worn_u100k_cleaned/ivectors_dev_worn_hires/ivector_online.scp --online-ivector-period=10 --frame-subsampling-factor=3 --frames-per-chunk=140 --extra-left-context=0 --extra-right-context=0 --extra-left-context-initial=0 --extra-right-context-final=0 --minimize=false --max-active=7000 --min-active=200 --beam=15.0 --lattice-beam=8.0 --acoustic-scale=1.0 --allow-partial=true --word-symbol-table=exp/chain_train_worn_u100k_cleaned/tree_sp/graph/words.txt exp/chain_train_worn_u100k_cleaned/tdnn1a_sp/final.mdl exp/chain_train_worn_u100k_cleaned/tree_sp/graph/HCLG.fst "ark,s,cs:apply-cmvn --norm-means=false --norm-vars=false --utt2spk=ark:data/dev_worn_hires/split8/1/utt2spk scp:data/dev_worn_hires/split8/1/cmvn.scp scp:data/dev_worn_hires/split8/1/feats.scp ark:- |" "ark:|lattice-scale --acoustic-scale=10.0 ark:- ark:- | gzip -c >exp/chain_train_worn_u100k_cleaned/tdnn1a_sp/decode_dev_worn/lat.1.gz"
