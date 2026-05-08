#!/bin/bash
set -e

# Install dependencies directly into lambda/ directory
# Terraform's archive_file data source zips lambda/ directory, so dependencies must be there
cd lambda

python3 -m pip install -r requirements.txt -t . --quiet

cd ..

echo "Dependencies installed into lambda/ directory"
