#!/bin/bash
###########################################################################
#
#  Copyright 2026 Google LLC
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#
###########################################################################

set -e

echo "~~~~~~~~ Welcome ~~~~~~~~~~"

read -p "Please enter your GCP PROJECT ID: " project_id
echo "Enabling required APIs."
gcloud services enable bigquery.googleapis.com --async --project="$project_id" || \
    echo "WARNING: Could not enable bigquery.googleapis.com (it may already be enabled). Continuing."
read -p "Please enter BigQuery location/region [default: US]: " location
location=${location:-US}
read -p "Please enter a new BigQuery dataset name (cannot include spaces): " dataset_id
echo "~~~~~~~~ Creating BigQuery Dataset ~~~~~~~~~~"
bq mk --location="$location" -d "$project_id:$dataset_id"
echo "~~~~~~~~ BigQuery Dataset Created ~~~~~~~~~~"

read -p "Please enter a new BigQuery table name (cannot include spaces): " table_id
echo "~~~~~~~~ Creating BigQuery Table ~~~~~~~~~~"
bq mk -t \
    --location="$location" \
    --time_partitioning_type=DAY \
    --clustering_fields=event_name,ga_session_id \
    --schema=./sgtm_ga4_to_bigquery_schema.json \
    "$project_id:$dataset_id.$table_id"
echo "~~~~~~~~ BigQuery Table Created ~~~~~~~~~~"

echo "***************************
*
* Setup Complete!
*
* The BigQuery table you must use with the server-side Tag Manager
* GA4 to BigQuery tag template has been created.
*
* Use the following settings when setting up the tag:
* - Project ID: $project_id
* - Dataset ID: $dataset_id
* - Table ID: $table_id
* - Location: $location
***************************"
