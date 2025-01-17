#!/bin/bash

set -xeuo pipefail

if (( $# != 1)); then
    echo "run using $0 <PREFIX>"
    exit 1
fi

PREFIX="$1"
GSBUCKET="gs://bee_living_sensor_obj_detection"
MAXITER=6000

#
# SETUP GSUTILS
#
GCLOUD="gcloud"
GSUTIL="gsutil"
$GCLOUD auth activate-service-account --key-file=bee-living-sensor-da7ae770e263.json

#
# DATA PREPARATION
#
# download all datasets from gstorage
mkdir -p "$HOME/data/" "$HOME/backup-${PREFIX}/"
$GSUTIL ls -r "${GSBUCKET}/"** | grep .zip | grep -E -v "(fileshare|mturk)" > ~/available_datasets.txt
$GSUTIL cp -n $(cat available_datasets.txt) ~/data/
cd ~/data
unzip -qu \*.zip
cd

# take all image files in validate/ or test/ folders and write full path to test.txt
find data/ -type f -regextype sed -regex ".*\(jpeg\|jpg\|png\)" | grep -E "(/validate/|/test/)" | xargs realpath > test.txt
# take all other image files and write full path to train.txt
find data/ -type f -regextype sed -regex ".*\(jpeg\|jpg\|png\)" | grep -E -v "(/validate/|/test/)" | xargs realpath > train.txt

#
# SETUP DARKNET
#
if [[ ! -d darknet ]]; then
    sudo apt-get -y install nvidia-cuda-toolkit
    git clone https://github.com/AlexeyAB/darknet darknet/
    cd darknet
    sed -i 's/OPENCV=0/OPENCV=1/' Makefile
    sed -i 's/GPU=0/GPU=1/' Makefile
    sed -i 's/CUDNN=0/CUDNN=1/' Makefile
    sed -i 's/CUDNN_HALF=0/CUDNN_HALF=1/' Makefile
    make
    chmod +x darknet
    cd
fi
cd darknet

#
# DOWNLOAD WEIGHTS & CONFIG
#
$GSUTIL cp "${GSBUCKET}/yolov4-custom.cfg" .
wget -N https://github.com/AlexeyAB/darknet/releases/download/darknet_yolo_v3_optimal/yolov4.conv.137

#
# SETUP CONFIG
#
# more subdivisions -> less GPU memory consumed
sed -i -E "s/subdivisions=[[:digit:]]{2}/subdivisions=32/" yolov4-custom.cfg
# both width & height need to be a multiple of 32
# small: 224; medium: 416; large: 608
sed -i -E "s/width=[[:digit:]]{3}/width=608/" yolov4-custom.cfg
sed -i -E "s/height=[[:digit:]]{3}/height=608/" yolov4-custom.cfg
# learning rate decay
sed -i -E "s/scales=\.[[:digit:]],\.[[:digit:]]/scales=.1,.2/" yolov4-custom.cfg

# make obj.names and obj.data
printf "bee\n" > obj.names
printf 'classes = 2\ntrain = %s/train.txt\nvalid = %s/test.txt\nnames = obj.names\n' "$HOME" "$HOME" > obj.data
printf 'backup = %s/backup-%s\n' "$HOME" "$PREFIX" >> obj.data

# run training, single GPU start
sed -i -E 's:max_batches = [0-9]{1,2}000:max_batches = 1000:' yolov4-custom.cfg
weightsfile=yolov4.conv.137
./darknet detector train obj.data yolov4-custom.cfg "$weightsfile" -dont_show -map
# switch to multip gpu
sed -i -E "s:max_batches = [0-9]{1,2}000:max_batches = ${MAXITER}:" yolov4-custom.cfg
weightsfile="$HOME/backup-${PREFIX}/yolov4-custom_1000.weights"
./darknet detector train obj.data yolov4-custom.cfg "$weightsfile" -dont_show -map -gpus 0,1
cd

#
# UPLOAD WEIGHTS
#
# these are the same as the yolov4-custom_MAXITER.weights file
rm "backup-${PREFIX}/yolov4-custom_final.weights"
rm "backup-${PREFIX}/yolov4-custom_last.weights"
$GSUTIL cp -n -r "backup-${PREFIX}" "$GSBUCKET"

#
# CALC SCORES
#
# total score on all hives, for each .weights file produced
cd darknet
scorefile=scores-$PREFIX.txt
if [[ ! -f "$scorefile" ]]; then
    for weights in ~/backup-${PREFIX}/*; do
        printf 'Current: %s\n\n' "$(basename $weights)" >> "$scorefile"
        ./darknet detector map obj.data yolov4-custom.cfg "$weights" -thresh 0.25 >> "$scorefile"
    done
fi
$GSUTIL cp "$scorefile" "$GSBUCKET"
cd "$HOME"

# for the final weight: scores per hive
final_weights="backup-${PREFIX}/yolov4-custom_${MAXITER}.weights"
if [[ -f $final_weights ]]; then
    ./eval_each_folder.sh "$PREFIX" "$final_weights"
    $GSUTIL cp "darknet/scores-each-${PREFIX}.txt" "$GSBUCKET"
fi

#
# CLEANUP
#
rm -r "backup-${PREFIX}"
rm -r data
rm -r darknet/yolov4-custom.cfg
