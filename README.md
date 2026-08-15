[English](README.md) | [简体中文](README_cn.md)

## Google Analytics 4 to BigQuery Tag Template

This is not an officially supported Google product.


## Summary

This repository contains the code for the GA4 to BigQuery Tag template and the schema for the corresponding table in BigQuery. The tag template automatically streams GA4 hits from Server-Side Google Tag Manager (sGTM) to BigQuery in near real-time. Each hit is written as a separate row in BigQuery with support for batched events, Consent Mode v2, and Google Ads traffic attribution.


## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Web / App Client (gtag.js / GTM Web)                     │
└──────────────────────────────┬──────────────────────────────┘
                               │ HTTPS (GA4 hits)
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Server-Side GTM Container (Hosted on Google Cloud Run)   │
│    ├─ GA4 Client (parses incoming MPv2 requests)            │
│    └─ GA4 to BigQuery Tag (template.tpl)                    │
└──────────────────────────────┬──────────────────────────────┘
                               │ BigQuery Streaming Insert API
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Google Cloud BigQuery (Created via deploy.sh)            │
│    └─ Dataset -> Table (partitioned by day & clustered)     │
└─────────────────────────────────────────────────────────────┘
```


## Prerequisites & GCP Permissions

Before starting, ensure you have the required access in Google Cloud Platform (GCP):

### 1. User Account Permissions
To set up sGTM and create BigQuery resources, your Google account needs:
* **GCP Project Role**: **Editor** or **Owner** (or `roles/run.admin`, `roles/resourcemanager.projectIamAdmin`, and `roles/bigquery.admin`).
* **Billing Account Access**: **Billing Account User** or **Administrator** on the linked Google Cloud billing account.

### 2. Service Account Permissions (Cloud Run to BigQuery)
When sGTM runs on Cloud Run, it uses a Service Account (typically the Compute Engine default service account `<project-number>-compute@developer.gserviceaccount.com` or a dedicated service account). 

To stream data into BigQuery, this service account must have:
* **BigQuery Data Editor** (`roles/bigquery.dataEditor`) on the dataset or project.
* **BigQuery Job User** (`roles/bigquery.jobUser`) on the GCP project.

> [!NOTE]
> In standard GCP projects where default IAM roles have not been modified, the default Compute Engine service account already has the **Editor** role, which includes BigQuery write permissions **within the same project**. Because automatic provisioning creates its own GCP project, if your BigQuery table lives in a different project than the tagging server, or your organization enforces least-privilege IAM, explicitly grant `roles/bigquery.dataEditor` and `roles/bigquery.jobUser` on the BigQuery project to the service account used by Cloud Run.


---


## Step-by-Step Setup Guide

### Step 1: Provision the Server-Side GTM Container on Cloud Run (Automatic)

The easiest way to deploy sGTM is using Google Tag Manager's **automatic provisioning**, which creates and manages the Cloud Run service in your GCP project for you without requiring manual container setup.

1. Go to [Google Tag Manager](https://tagmanager.google.com/).
2. Create a new container (or select an existing account), and choose **Server** as the target platform.
3. In the setup dialog, choose **Automatically provision tagging server**.
4. Select or link your **GCP Billing Account**.
5. GTM will automatically create a new GCP project and deploy the tagging server to **Google Cloud Run**. (To deploy into an existing GCP project instead, use the [manual Cloud Run setup](https://developers.google.com/tag-platform/tag-manager/server-side/cloud-run-setup-guide).)
6. Once deployment finishes (typically 2–5 minutes), GTM displays your **Default URL** (e.g. `https://gtm-xxxxxx-uc.a.run.app`). Save this URL as your server-side tagging endpoint.


### Step 2: Create the BigQuery Dataset & Table

For hit data to be successfully written to BigQuery, you must create a BigQuery dataset and table using the provided schema. 

Open **Google Cloud Shell** in your GCP project and run:

```bash
rm -rf sgtm-ga4-to-bigquery && git clone https://github.com/cloudymoma/sgtm-ga4-to-bigquery.git && cd sgtm-ga4-to-bigquery && bash deploy.sh
```

The script will:
1. Prompt for your **GCP Project ID**.
2. Enable the BigQuery API (`bigquery.googleapis.com`) in that project.
3. Prompt for your **BigQuery Location/Region** (e.g. `US`, `EU`, `asia-northeast1`, default: `US`).
4. Prompt for your **Dataset ID** and **Table ID**.
5. Create the dataset and table with daily partitioning and clustering on `event_name` and `ga_session_id`.


### Step 3: Import & Configure the Tag Template in sGTM

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
	* Fill in the required fields:
		* **Cloud Project ID**: Your GCP Project ID.
		* **BigQuery Dataset ID**: The dataset ID created in Step 2.
		* **BigQuery Table ID**: The table ID created in Step 2.
		* **Measurement ID**: Enter `*` to match all measurement IDs, or specify your stream ID (e.g. `G-XXXXXXXXXX`).
		* **Write IP Address**: Check this box if you want to capture the client IP address in BigQuery.

3. **Set the Trigger**:
	* Click on **Triggering**.
	* Select or create a **Custom** trigger set to fire on **All Events** (or filter by specific Client/Event names).
	* Name and save the trigger.

4. **Publish**:
	* Save the tag.
	* Click **Submit** in the upper-right corner and **Publish** the container.


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
