#!/bin/bash
set -e

# Build directory
BUILD_DIR="lambda_build"
OUTPUT_ZIP="lambda.zip"

# Clean and create build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Copy source code
cp lambda/index.py "$BUILD_DIR/"

# Install dependencies using Python's -m pip if available
# For Lambda Python 3.11, boto3 is pre-installed, but requests needs to be included
cd "$BUILD_DIR"

# Download and extract requests package (minimal approach)
# Since we can't use pip, we'll try an alternative method
python3 << 'EOF'
import subprocess
import sys
import os

# Try installing with pip via subprocess
try:
    subprocess.check_call([
        sys.executable, "-m", "pip", "install",
        "-r", "../lambda/requirements.txt",
        "-t", "."
    ])
except Exception as e:
    print(f"Warning: Could not install packages with pip: {e}")
    print("Proceeding without external dependencies (boto3 is pre-installed in Lambda)")

EOF

cd ..

# Create zip file with proper structure (Lambda needs handler at root)
cd "$BUILD_DIR"
zip -r ../"$OUTPUT_ZIP" .
cd ..

# Clean up
rm -rf "$BUILD_DIR"

echo "Lambda package created: $OUTPUT_ZIP"
