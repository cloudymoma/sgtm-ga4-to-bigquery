[English](README.md) | [简体中文](README_cn.md)

## Google Analytics 4 to BigQuery Tag Template

This is not an officially supported Google product.


## Summary

This repository contains the code for the GA4 to BigQuery Tag template and the schema for the corresponding table in BigQuery. The tag template automatically streams GA4 hits from Server-Side Google Tag Manager (sGTM) to BigQuery in near real-time. Each hit is written as a separate row in BigQuery with support for batched events, Consent Mode v2, and Google Ads traffic attribution.


## Architecture Overview (Centralized GCP Projects)

All of your sGTM tagging servers run as **Cloud Run** services in **one** GCP project — one Cloud Run service per GTM server container. Every service streams its data into **one centralized BigQuery project**, with a **separate dataset per container**. The Cloud Run project and the BigQuery project can be the same project, or two different ones — the steps below work for both setups.

This avoids the classic "one GCP project per GTM container" sprawl: unified billing, one place to look, and simple IAM permissions.

```
┌──────────────────────────────────────────────────────────────┐
│ 1. Web / App Clients (gtag.js / GTM Web)                     │
└──────────────────────────────┬───────────────────────────────┘
                               │ HTTPS (GA4 hits)
                               ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. sGTM GCP Project (ALL tagging servers in ONE project)     │
│                                                              │
│    Cloud Run service "gtm-server-site1"  ← GTM container 1   │
│    Cloud Run service "gtm-server-site2"  ← GTM container 2   │
│    Cloud Run service "gtm-server-..."    ← one per container │
└──────────────────────────────┬───────────────────────────────┘
                               │ BigQuery Streaming API
                               ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. Centralized BigQuery Project (can be the SAME project)    │
│                                                              │
│    analytics_site1.events  ← data from gtm-server-site1      │
│    analytics_site2.events  ← data from gtm-server-site2      │
│    (each table Partitioned by Day & Clustered)               │
└──────────────────────────────────────────────────────────────┘
```


## Prerequisites & GCP Permissions

Before starting, ensure you have access to your existing Google Cloud Project:

### 1. User Account Permissions
To deploy Cloud Run and create BigQuery resources, your Google account needs:
* **GCP Project Role**: **Editor** or **Owner** on the project(s) you will use (or specifically `roles/run.admin`, `roles/iam.serviceAccountUser`, and `roles/bigquery.admin`).

### 2. Service Account Permissions (Cloud Run → BigQuery)

**If Cloud Run and BigQuery share the same GCP project (simplest):** nothing to do. The default Compute Engine service account (`<project-number>-compute@developer.gserviceaccount.com`) used by Cloud Run already has the **Editor** role, so it can write to BigQuery out of the box.

**If BigQuery lives in a separate centralized project:** run this once. Edit the first 2 lines, then copy & paste the whole block into Cloud Shell:

```bash
SGTM_PROJECT_ID="my-sgtm-project"    # <-- the project running your sGTM Cloud Run services
BQ_PROJECT_ID="my-bigquery-project"  # <-- the centralized BigQuery project

PROJECT_NUMBER=$(gcloud projects describe "$SGTM_PROJECT_ID" --format="value(projectNumber)")
gcloud projects add-iam-policy-binding "$BQ_PROJECT_ID" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/bigquery.dataEditor"
gcloud projects add-iam-policy-binding "$BQ_PROJECT_ID" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/bigquery.jobUser"
```

> [!NOTE]
> If your organization enforces strict least-privilege IAM, simply ensure the Cloud Run service account has:
> * **BigQuery Data Editor** (`roles/bigquery.dataEditor`) on the dataset (or the BigQuery project).
> * **BigQuery Job User** (`roles/bigquery.jobUser`) on the BigQuery project.


---


## Step-by-Step Setup Guide

### Step 1: Get the Container Config String from GTM

1. Open [Google Tag Manager](https://tagmanager.google.com/).
2. Create a new container (or open an existing one), and choose **Server** as the target platform.
3. In the setup dialog, choose **Manually provision tagging server**.
4. Copy your **Container Config** string (a long string starting with `aWQ9...`).


### Step 2: Deploy Cloud Run into Your Existing GCP Project

Open **Google Cloud Shell** (click the `>_` icon in the top-right corner of the [Google Cloud Console](https://console.cloud.google.com/)).

Edit the first 3 lines below, then copy & paste the whole block to deploy:

```bash
PROJECT_ID="my-sgtm-project"     # <-- your GCP project ID (hosts ALL your sGTM servers)
SERVICE_NAME="gtm-server-site1"  # <-- pick a unique name for THIS GTM container
CONTAINER_CONFIG="aWQ9..."       # <-- the Container Config string from Step 1

gcloud config set project "$PROJECT_ID"
gcloud run deploy "$SERVICE_NAME" \
  --image="gcr.io/cloud-tagging-10302018/gtm-cloud-image:stable" \
  --region=us-central1 \
  --set-env-vars="CONTAINER_CONFIG=$CONTAINER_CONFIG" \
  --cpu=1 \
  --memory=512Mi \
  --min-instances=1 \
  --max-instances=10 \
  --allow-unauthenticated
```

> [!TIP]
> * **Have more than one GTM container?** Run the same block again with a different `SERVICE_NAME` and that container's own `CONTAINER_CONFIG`. All services live side by side in the same GCP project.
> * You can change `--region=us-central1` to your preferred region (e.g. `europe-west1`, `asia-northeast1`).

Once the command finishes, Cloud Run will output your **Service URL** (e.g., `https://gtm-server-xxxxxx-uc.a.run.app`). 

**Connect URL back to GTM**:
1. In Google Tag Manager, navigate to **Admin** → **Container Settings**.
2. Under **Server container URLs**, click **Add URL** and paste your Cloud Run Service URL.
3. Click **Save**.


### Step 3: Create the BigQuery Dataset & Table

In the same **Google Cloud Shell**, run the automated setup script:

```bash
rm -rf sgtm-ga4-to-bigquery && git clone https://github.com/cloudymoma/sgtm-ga4-to-bigquery.git && cd sgtm-ga4-to-bigquery && bash deploy.sh
```

The script will:
1. Prompt for your **GCP Project ID**.
2. Enable the BigQuery API (`bigquery.googleapis.com`) in that project.
3. Prompt for your **BigQuery Location/Region** (e.g. `US`, `EU`, `asia-northeast1`, default: `US`).
4. Prompt for your **Dataset ID** (e.g. `analytics_site1`) and **Table ID** (e.g. `events`).
5. Create the dataset and table with daily partitioning and clustering on `event_name` and `ga_session_id`.

> [!TIP]
> * When asked for the **GCP Project ID**, enter your **centralized BigQuery project** ID — it can be the same project you deployed Cloud Run into in Step 2, or a different one (see [Prerequisites](#prerequisites--gcp-permissions) for the one-time permission setup in that case).
> * **Have more than one GTM container?** Run `bash deploy.sh` once per container and give each its own **Dataset ID** (e.g. `analytics_site1`, `analytics_site2`). All datasets live together in the same BigQuery project.


### Step 4: Import & Configure the Tag Template in sGTM

1. **Import the Template**:
	* Download [`template.tpl`](template.tpl) from this repository to your computer.
	* Open your GTM Server Container workspace at [tagmanager.google.com](https://tagmanager.google.com/).
	* Navigate to **Templates** in the left sidebar.
	* Under **Tag Templates**, click **New**.
	* Click the three dots menu (overflow menu) in the upper-right corner and select **Import**.
	* Select `template.tpl` and click **Save**.

2. **Create the Tag**:
	* Navigate to **Tags** and click **New**.
	* Click **Tag Configuration** and select **GA4 to BigQuery** (under *Custom*).
	* Fill in the configuration fields:
		* **Cloud Project ID**: The BigQuery project ID you entered in Step 3.
		* **BigQuery Dataset ID**: The dataset ID created in Step 3 (each GTM container uses its own dataset).
		* **BigQuery Table ID**: The table ID created in Step 3.
		* **Measurement ID**: Enter `*` to match all measurement IDs, or specify your stream ID (e.g. `G-XXXXXXXXXX`).
		* **Write IP Address**: Check this box if you want to capture the client IP address in BigQuery.

3. **Set the Trigger**:
	* Click on **Triggering**.
	* Select or create a **Custom** trigger set to fire on **All Events** (or filter by specific Client/Event names).
	* Name and save the trigger.

4. **Publish**:
	* Save the tag.
	* Click **Submit** in the upper-right corner and **Publish** the container version.


---


## Tag Fields Reference

*   **Measurement ID**
    *   Enter either the measurement ID for the hits you want written to BigQuery (e.g. `G-XXXXXXXXXX`), or enter `*` to match all measurement IDs. The field defaults to `*`.
*   **Write IP Address**
    *   Check the box (or provide a variable that resolves to `true` or `false`) to include the originating IP address in BigQuery using the `getRemoteAddress()` API.
*   **BigQuery Settings**
    *   Enter the Google Cloud Project ID, BigQuery Dataset ID, and BigQuery Table ID in their respective fields.


## Data Collected & Schema Details

The tag captures:
*   Standard GA4 Event parameters (`event_name`, `event_timestamp`, `ga_session_id`, `ga_session_number`, `session_engagement`, `page_location`, `page_title`, `page_referrer`, `page_encoding`, `language`, `screen_resolution`, etc.)
*   Traffic & Campaign attribution (`gclid`, `dclid`, `gbraid`, `wbraid`, `gclsrc`, `_gl`, `gad_source`, `source`, `medium`, `campaign`, `term`, `content`, `creative_format`, `marketing_tactic`, `source_platform`, `campaign_id`)
*   Consent states: Consent Mode v1 (`gcs`), Consent Mode v2 (`gcd`), Digital Markets Act (`dma`), and Non-Personalized Ads (`npa`)
*   Custom event parameters (`event_params` array of key-value records including `string_value`, `int_value`, and `float_value`)
*   Custom user properties (`user_properties` array of key-value records including `string_value`, `int_value`, and `float_value`)
*   Ecommerce items array (`items`)

### Data Not Collected
*   Geographic information derived server-side (country, region, city) unless forwarded in custom parameters
*   Google Signals data
*   Dimensions that rely on server-side parsing of the user agent string (raw user-agent string is collected)
