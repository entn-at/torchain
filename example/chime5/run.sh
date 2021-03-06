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


# path config
chime5_dir=$KALDI_ROOT/egs/chime5/s5
exp_dir=$KALDI_ROOT/egs/chime5/s5/exp
recog_set="dev_worn dev_beamformit_ref"
chain_dir=$exp_dir/chain_train_worn_u100k_cleaned
egs_dir=$chain_dir/tdnn1a_sp/egs

# training config
use_ivector=True
n_epoch=10
optim=Adam
lr=1e-3
xent_regularize=0.0
model_dir=
ngpu=1
weight_decay=5e-5
batchsize=256
accum_grad=1
# decoding config
min_active=200
max_active=700
max_mem=50000000
beam=15.0
lattice_beam=8.0
acwt=1.0
graphdir=$chain_dir/tree_sp/graph
trans_model=$chain_dir/tdnn1a_sp/final.mdl
scoring_opts="--min-lmwt 4 --max-lmwt 15 --word_ins_penalty 0.0,0.5,1.0"
lda_mat=$chain_dir/tdnn1a_sp/lda.mat
post_acwt=10.0
# misc config
stage=0
momentum=0.0

. ./parse_options.sh || exit 1;

ln -sf $chime5_dir/utils .

if [ -d $chain_dir/tdnn1a_sp/egs/cegs1.ark ]; then
    echo "cegs*.ark not found. use local/chain/run_tdnn.sh --remove-egs false"
fi

if [ -d $trans_model ]; then
    echo "$trans_model is not found"
    exit 1;
fi

train_opt=""
if [ -z $lda_mat ]; then
    use_lda=""
else
    use_lda="_lda"
    train_opt="${train_opt} --lda_mat ${lda_mat}"
fi
if [ $use_ivector = True ]; then
    use_ivector="_ivec"
else
    use_ivector=""
    train_opt="${train_opt} --no_ivector"
fi

if [ -z $model_dir ]; then
    model_dir=exp/torchain0.5_${optim}_lr${lr}_mo${momentum}_wd${weight_decay}_bs${batchsize}_epoch${n_epoch}_ag${accum_grad}_xent${xent_regularize}${use_lda}${use_ivector}
fi

mkdir -p $model_dir
scp_dir=exp/scp

if [ $stage -le 0 ] && [ ! -f $scp_dir/train.scp ]; then
    echo "=== stage 0: prepare scp"
    mkdir -p $scp_dir

    # # TODO use decode_cmd
    # for ark in $egs_dir/cegs.*.ark; do
    #     echo $ark
    #     python ark2scp.py $ark >> $scp_dir/train_egs.scp
    # done
    # python ark2scp.py $egs_dir/valid_diagnostic.cegs.ark > $scp_dir/valid_egs.scp
    # python -c "from torchain.io import print_key_length; print_key_length('scp:${scp_dir}/train_egs.scp', '${scp_dir}/train_egs.scp.len')"
    # python -c "from torchain.io import print_key_length; print_key_length('scp:${scp_dir}/valid_egs.scp', '${scp_dir}/valid_egs.scp.len')"

    # prepare valid.scp
    ${decode_cmd} $scp_dir/log/valid.scp.log \
                  python ark2scp.py $egs_dir/valid_diagnostic.cegs --scp $scp_dir/valid.scp || exit 1
    ${decode_cmd} $scp_dir/log/valid.scp.len.log \
                  python -c "from torchain.io import print_key_length; print_key_length('scp:${scp_dir}/valid.scp', '${scp_dir}/valid.scp.len')" || exit 1

    # prepare train.scp
    negs=$(ls $egs_dir/cegs.*.ark | wc -l)

    ${decode_cmd} JOB=1:$negs $scp_dir/log/cegs.JOB.scp.log \
                  python ark2scp.py $egs_dir/cegs.JOB.ark --scp $scp_dir/cegs.JOB.scp || exit 1
    ${decode_cmd} JOB=1:$negs $scp_dir/log/cegs.JOB.scp.len.log \
                  python -c "from torchain.io import print_key_length; print_key_length('scp:${scp_dir}/cegs.JOB.scp', '${scp_dir}/cegs.JOB.scp.len')" || exit 1

    cat $scp_dir/cegs.*.scp > $scp_dir/train.scp || exit 1
    cat $scp_dir/cegs.*.scp.len > $scp_dir/train.scp.len || exit 1
fi

# TODO support multi GPU
if [ $stage -le 1 ]; then
    echo "=== stage 1: acoustic model training ==="; cp models.py $model_dir; cp train_faster.py $model_dir
    ${train_cmd} --gpu $ngpu $model_dir/log/train.log python train_faster.py \
                 --model_dir $model_dir \
                 --den_fst $chain_dir/tdnn1a_sp/den.fst \
                 --train_scp $scp_dir/train.scp --valid_scp $scp_dir/valid.scp \
                 --optim $optim --xent_regularize $xent_regularize --lr ${lr} --momentum ${momentum} --weight_decay ${weight_decay} \
                 --train_minibatch_size ${batchsize} --accum_grad ${accum_grad} --n_epoch ${n_epoch} ${train_opt}
fi

nj=20


# TODO merge stage 2 and 3 with pipe and remove forward/dev_worn_split.JOB.ark
if [ $stage -le 2 ]; then
    echo "=== stage 2: calc acoustic log-likelihood ==="
    mkdir -p $model_dir/forward
    for label in $recog_set; do
        aux_dir=$exp_dir/nnet3_train_worn_u100k_cleaned/ivectors_${label}_hires
        input_dir=$exp_dir/../data/${label}_hires/split$nj

        ${decode_cmd} \
            JOB=1:$nj $model_dir/log/forward_${label}.JOB.log \
            python forward.py \
            --aux_scp $aux_dir/ivector_online.scp \
            --input_rs "ark,s,cs:apply-cmvn --norm-means=false --norm-vars=false --utt2spk=ark:${input_dir}/JOB/utt2spk scp:${input_dir}/JOB/cmvn.scp scp:${input_dir}/JOB/feats.scp ark:- |" \
            --model_dir $model_dir \
            --forward_ark $model_dir/forward/${label}_split.JOB.ark || exit 1;
    done
fi



if [ $stage -le 3 ]; then
    echo "=== stage 3: decoding ==="
    for label in $recog_set; do
        decode_dir=$model_dir/decode/${label}
        mkdir -p $decode_dir
        ${decode_cmd} \
            JOB=1:$nj $model_dir/log/decode_${label}.JOB.log \
            latgen-faster-mapped \
            --min-active=$min_active --max-active=$max_active \
            --max-mem=$max_mem --beam=$beam \
            --lattice-beam=$lattice_beam --acoustic-scale=$acwt \
            --allow-partial=true --word-symbol-table=$graphdir/words.txt \
            $trans_model $graphdir/HCLG.fst \
            ark:$model_dir/forward/${label}_split.JOB.ark \
            "ark:|lattice-scale --acoustic-scale=${post_acwt} ark:- ark:- | gzip -c > ${decode_dir}/lat.JOB.gz" || exit 1;
    done
fi


if [ $stage -le 4 ]; then
    echo "=== stage 4: evaluation ==="
    # see compute_wer.sh in chime5
    for label in $recog_set; do
        decode_dir=$(pwd)/$model_dir/decode/${label}
        data_dir=$chime5_dir/data/$label
        scoring_opts="--min-lmwt 4 --max-lmwt 15 --word_ins_penalty -1.0,-0.5,0.0"
        cd $chime5_dir; local/score.sh $scoring_opts --cmd "${decode_cmd}" $data_dir $graphdir $decode_dir || exit 1; cd -
    done

    for label in $recog_set; do
        decode_dir=$model_dir/decode/${label}
        cat $decode_dir/scoring_kaldi/best_wer
    done
fi
# nnet3-latgen-faster-parallel --num-threads=4 --online-ivectors=scp:exp/nnet3_train_worn_u100k_cleaned/ivectors_dev_worn_hires/ivector_online.scp --online-ivector-period=10 --frame-subsampling-factor=3 --frames-per-chunk=140 --extra-left-context=0 --extra-right-context=0 --extra-left-context-initial=0 --extra-right-context-final=0 --minimize=false --max-active=7000 --min-active=200 --beam=15.0 --lattice-beam=8.0 --acoustic-scale=1.0 --allow-partial=true --word-symbol-table=exp/chain_train_worn_u100k_cleaned/tree_sp/graph/words.txt exp/chain_train_worn_u100k_cleaned/tdnn1a_sp/final.mdl exp/chain_train_worn_u100k_cleaned/tree_sp/graph/HCLG.fst "ark,s,cs:apply-cmvn --norm-means=false --norm-vars=false --utt2spk=ark:data/dev_worn_hires/split8/1/utt2spk scp:data/dev_worn_hires/split8/1/cmvn.scp scp:data/dev_worn_hires/split8/1/feats.scp ark:- |" "ark:|lattice-scale --acoustic-scale=10.0 ark:- ark:- | gzip -c >exp/chain_train_worn_u100k_cleaned/tdnn1a_sp/decode_dev_worn/lat.1.gz"
