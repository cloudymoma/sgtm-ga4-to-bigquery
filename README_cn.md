[English](README.md) | [简体中文](README_cn.md)

## Google Analytics 4 (GA4) 至 BigQuery 代码模板 (Tag Template)

这不是 Google 官方支持的产品。


## 概述

本代码仓库包含 GA4 至 BigQuery 的服务端代码模板（Tag Template）以及 BigQuery 中对应数据表的架构（Schema）。该代码模板能够将服务端 Google 代码管理器（sGTM, Server-Side Google Tag Manager）接收到的 GA4 数据近乎实时地自动写入 BigQuery。每条匹配的数据都会作为独立的一行写入 BigQuery，并支持批量事件（Batch Events）、Consent Mode v2（同意义见模式 v2）以及 Google Ads 广告归因等功能。


## 系统架构概览

```
┌─────────────────────────────────────────────────────────────┐
│ 1. 客户端 / 浏览器 / App (gtag.js / GTM Web)                  │
└──────────────────────────────┬──────────────────────────────┘
                               │ HTTPS 请求 (GA4 hits)
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. 服务端 GTM 容器 (托管于 Google Cloud Run)                  │
│    ├─ GA4 客户端 (解析 incoming MPv2 请求)                    │
│    └─ GA4 to BigQuery 代码模板 (template.tpl)                │
└──────────────────────────────┬──────────────────────────────┘
                               │ BigQuery Streaming Insert API
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Google Cloud BigQuery (通过 deploy.sh 创建)               │
│    └─ 数据集 (Dataset) -> 数据表 (按天分区与聚簇)               │
└─────────────────────────────────────────────────────────────┘
```


## 前置条件与 GCP 权限要求

在开始配置前，请确保您的 Google 账号与服务账号在 Google Cloud Platform (GCP) 中拥有相应权限：

### 1. 用户账号权限
用于在 GTM 中自动部署 Cloud Run 服务以及运行 `deploy.sh` 创建 BigQuery 资源：
* **GCP 项目角色**：**Editor (编辑者)** 或 **Owner (所有者)**（或具备 `roles/run.admin`、`roles/resourcemanager.projectIamAdmin` 和 `roles/bigquery.admin` 权限）。
* **结算账号权限**：关联的 Google Cloud 结算账号中的 **Billing Account User (结算账号用户)** 或 **Billing Account Administrator (结算账号管理员)**。

### 2. 服务账号权限（Cloud Run 写入 BigQuery）
sGTM 运行在 Cloud Run 上时，使用的是 GCP 服务账号（通常为 Compute Engine 默认服务账号 `<project-number>-compute@developer.gserviceaccount.com` 或自定义服务账号）。

为了将数据流式写入 BigQuery，该服务账号需要具备：
* **BigQuery Data Editor (BigQuery 数据编辑者)** (`roles/bigquery.dataEditor`)：在目标数据集或项目上。
* **BigQuery Job User (BigQuery 作业用户)** (`roles/bigquery.jobUser`)：在 GCP 项目上。

> [!NOTE]
> 在未修改过默认 IAM 角色的标准 GCP 项目中，Compute Engine 默认服务账号已经拥有 **Editor** 角色（包含**同一项目内**的 BigQuery 写入权限）。由于自动配置会创建独立的 GCP 项目，如果 BigQuery 数据表与代码植入服务器不在同一项目中，或您的组织启用了严格的最小权限控制，请在 BigQuery 所在项目中向 Cloud Run 使用的服务账号显式授予上述两个角色。


---


## 详细配置步骤

### 步骤 1：在 Cloud Run 上自动部署服务端 GTM（推荐，最简流程）

部署 sGTM 最简单的方式是使用 Google Tag Manager 的**自动配置功能**。GTM 将自动在您的 GCP 项目中创建并托管 Cloud Run 服务，无需手动编写容器配置。

1. 登录 [Google Tag Manager 控制台](https://tagmanager.google.com/)。
2. 创建一个新容器（或选择现有账号并新建容器），目标平台选择 **Server (服务端)**。
3. 在弹出的初始配置窗口中，选择 **Automatically provision tagging server (自动配置代码植入服务器)**。
4. 选择或关联您的 **GCP 结算账号 (Billing Account)**。
5. GTM 将自动创建一个新的 GCP 项目，并在 **Google Cloud Run** 上部署该代码植入服务器。（如需部署到现有 GCP 项目，请改用[手动 Cloud Run 部署方式](https://developers.google.com/tag-platform/tag-manager/server-side/cloud-run-setup-guide)。）
6. 部署完成后（通常需要 2–5 分钟），GTM 会显示分配的 **默认网址 (Default URL)**（例如 `https://gtm-xxxxxx-uc.a.run.app`）。请保存该地址作为服务端数据收集接口。


### 步骤 2：创建 BigQuery 数据集与数据表

为了使数据能够成功写入 BigQuery，必须先创建一个具有正确架构的数据集与数据表。

在您的 GCP 控制台中打开 **Google Cloud Shell**，运行以下命令：

```bash
rm -rf sgtm-ga4-to-bigquery && git clone https://github.com/cloudymoma/sgtm-ga4-to-bigquery.git && cd sgtm-ga4-to-bigquery && bash deploy.sh
```

该脚本将自动执行以下操作：
1. 提示输入您的 **GCP 项目 ID (Project ID)**。
2. 在该项目中启用 BigQuery API (`bigquery.googleapis.com`)。
3. 提示选择 **BigQuery 区域/位置 (Location/Region)**（例如 `US`、`EU`、`asia-northeast1`，默认 `US`）。
4. 提示输入 **数据集 ID (Dataset ID)** 与 **数据表 ID (Table ID)**。
5. 自动创建支持按天分区（Partitioning）并在 `event_name` 和 `ga_session_id` 上聚簇（Clustering）的数据表。


### 步骤 3：在 sGTM 中导入并配置代码模板

1. **导入模板**：
	* 从本仓库下载 [`template.tpl`](template.tpl) 文件到本地计算机。
	* 在 [tagmanager.google.com](https://tagmanager.google.com/) 中打开您的 GTM 服务端容器。
	* 点击左侧导航栏的 **模板 (Templates)**。
	* 在 **代码模板 (Tag Templates)** 区域点击 **新建 (New)**。
	* 点击右上角的三个点菜单（更多操作），选择 **导入 (Import)**。
	* 选择本地的 `template.tpl` 文件并点击 **保存 (Save)**。

2. **创建代码 (Tag)**：
	* 进入 **代码 (Tags)** 并点击 **新建 (New)**。
	* 点击 **代码配置 (Tag Configuration)**，在“自定义 (Custom)”分类下选择 **GA4 to BigQuery**。
	* 填写必要参数：
		* **Cloud Project ID**：您的 Google Cloud 项目 ID。
		* **BigQuery Dataset ID**：步骤 2 中创建的数据集 ID。
		* **BigQuery Table ID**：步骤 2 中创建的数据表 ID。
		* **Measurement ID**：输入 `*` 匹配所有衡量 ID，或指定特定数据流 ID（例如 `G-XXXXXXXXXX`）。
		* **Write IP Address**：如需记录用户客户端 IP，请勾选此项。

3. **设置触发条件 (Trigger)**：
	* 点击 **触发条件 (Triggering)**。
	* 选择或新建一个 **自定义 (Custom)** 触发器，触发条件设置为 **所有事件 (All Events)**（或根据特定客户端/事件名称进行过滤）。
	* 命名并保存触发器。

4. **发布容器**：
	* 保存该代码 (Tag)。
	* 点击右上角的 **提交 (Submit)** 并 **发布 (Publish)** 容器版本。


---


## 模板字段说明

*   **Measurement ID（衡量 ID）**
    *   输入需要写入 BigQuery 的数据流衡量 ID（例如 `G-XXXXXXXXXX`），或者输入 `*` 匹配所有衡量 ID。默认值为 `*`。
*   **Write IP Address（写入 IP 地址）**
    *   勾选该选项（或传入解析为 `true`/`false` 的变量），使用 `getRemoteAddress()` API 将请求的来源 IP 地址记录到 BigQuery 中。
*   **BigQuery Settings（BigQuery 设置）**
    *   在对应输入框中分别填入 Google Cloud 项目 ID (Project ID)、BigQuery 数据集 ID (Dataset ID) 以及 BigQuery 数据表 ID (Table ID)。


## 采集的数据与 Schema 详情

该模板采集以下数据：
*   标准 GA4 事件参数 (`event_name`, `event_timestamp`, `ga_session_id`, `ga_session_number`, `session_engagement`, `page_location`, `page_title`, `page_referrer`, `page_encoding`, `language`, `screen_resolution` 等)
*   流量与广告系列归因 (`gclid`, `dclid`, `gbraid`, `wbraid`, `gclsrc`, `_gl`, `gad_source`, `source`, `medium`, `campaign`, `term`, `content`, `creative_format`, `marketing_tactic`, `source_platform`, `campaign_id`)
*   用户授权同意状态 (Consent States)：Consent Mode v1 (`gcs`)、Consent Mode v2 (`gcd`)、数字市场法案 (`dma`) 以及非个性化广告 (`npa`)
*   自定义事件参数 (`event_params` 键值对数组，包含 `string_value`, `int_value`, `float_value`)
*   自定义用户属性 (`user_properties` 键值对数组，包含 `string_value`, `int_value`, `float_value`)
*   电子商务商品数组 (`items`)

### 未采集的数据
*   服务端推导的地理位置信息（国家/地区、省份、城市），除非在自定义参数中显式传递
*   Google Signals 数据
*   依赖于服务端解析 User-Agent 字符串的维度（会完整采集原始 User-Agent 字符串）
