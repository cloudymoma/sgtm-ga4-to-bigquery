[English](README.md) | [简体中文](README_cn.md)

## Google Analytics 4 to BigQuery Tag Template

This is not an officially supported Google product.


## Summary

This repository contains the code for the GA4 to BigQuery Tag template and the schema for the corresponding table in BigQuery. The tag template automatically streams GA4 hits from Server-Side Google Tag Manager (sGTM) to BigQuery in near real-time. Each hit is written as a separate row in BigQuery with support for batched events, Consent Mode v2, and Google Ads traffic attribution.


## BigQuery Table Setup

For the hit data to be successfully written to BigQuery, you must set up a BigQuery table with the correct schema. To create the dataset and table with daily partitioning and clustering, follow the steps in `deploy.sh` by entering the following into Cloud Shell:

```bash
rm -rf sgtm-ga4-to-bigquery && git clone https://github.com/cloudymoma/sgtm-ga4-to-bigquery.git && cd sgtm-ga4-to-bigquery && bash deploy.sh
```


## Tag Setup

1. Import the `template.tpl` file as a custom tag template in your server-side Tag Manager container:
	* Download `template.tpl` to your computer.
	* Open your GTM server container workspace.
	* Navigate to **Templates**.
	* Click **New** under Tag Templates.
	* In the upper-right corner, click the three dots menu (overflow menu) and select **Import**.
	* Select `template.tpl` and click **Save**.
2. Navigate to **Tags**, click **New**, click on **Tag Configuration**, and select **GA4 to BigQuery** under Custom.
3. Enter the necessary settings for the tag (Cloud Project ID, Dataset ID, and Table ID).
4. Set the tag’s trigger:
    1. Create a new **Custom** trigger.
    2. Set the trigger to fire on all events (or specific GA4 events).
    3. Name the trigger.
    4. Save the trigger.
5. Save the tag.
6. Publish the new container version.


## Tag Fields

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
