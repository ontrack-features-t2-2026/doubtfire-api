#!/bin/sh

# This script is copied into the TeX Live container and remotely executed by latex_run.sh

OUTPUT_DIR=$1
case "$OUTPUT_DIR" in
  ''|.|..|*/*|*\\*) exit 2 ;;
esac

cd "${TEXLIVE_WORK_ROOT:-/workdir/texlive-latex}/${OUTPUT_DIR}" || exit 1

# Initialise work subfolder
mkdir -p work
cp *.tex *.py work/
if [ -d assets ]; then
  cp -R assets work/ || exit 1
fi
cd work || exit 1

# Compile PDF
lualatex -shell-escape -interaction=batchmode -halt-on-error input.tex
RESULT=$?
if [ $RESULT -eq 0 ]; then
  echo "Running lualatex a second time to remove temporary last page and update references..."
  lualatex -shell-escape -interaction=batchmode -halt-on-error input.tex
  RESULT=$?
fi
if [ $RESULT -eq 0 ]; then
  echo "Running lualatex a third time to stabilise page references..."
  lualatex -shell-escape -interaction=batchmode -halt-on-error input.tex
  RESULT=$?
fi

# Copy PDF to parent directory and cleanup
cp *.log ../
cp *.pdf ../
cd ..
rm -rf work

exit $RESULT
