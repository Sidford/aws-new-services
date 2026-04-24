#!/bin/bash
# Test runner script for Lambda function tests
#
# This script sets up the test environment and runs comprehensive tests
# for both SCP management scenarios

set -e

echo "=========================================="
echo "AWS Service Monitor - Lambda Test Suite"
echo "=========================================="
echo ""

# Check Python version
echo "Checking Python version..."
python3 --version

# Create virtual environment
echo ""
echo "Creating virtual environment..."
if [ ! -d "venv" ]; then
    python3 -m venv venv
else
    echo "Virtual environment already exists"
fi

# Activate virtual environment
echo "Activating virtual environment..."
source venv/bin/activate

# Install dependencies
echo ""
echo "Installing test dependencies..."
pip install -q --upgrade pip
pip install -q pytest pytest-cov boto3 moto requests

# Set working directory
cd "$(dirname "$0")"

# Run tests with coverage
echo ""
echo "Running tests..."
echo "=========================================="
echo ""

pytest test_index.py -v --tb=short --color=yes \
    --cov=index \
    --cov-report=term-missing \
    --cov-report=html:htmlcov

echo ""
echo "=========================================="
echo "Tests completed!"
echo ""
echo "Test report generated in: htmlcov/index.html"
echo ""

# Summary
echo "Test Coverage Summary:"
echo "- TestNewServiceDetectionWithoutSCP"
echo "- TestNewServiceDetectionWithSCP"
echo "- TestEmailNotifications"
echo "- TestBaselineIntegrity"
echo "- TestServiceRemovalAndRediscovery"
