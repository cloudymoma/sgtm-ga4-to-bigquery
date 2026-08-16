[English](README.md) | [简体中文](README_cn.md)

## Google Analytics 4 (GA4) 至 BigQuery 代码模板 (Tag Template)

这不是 Google 官方支持的产品。


## 概述

本代码仓库包含 GA4 至 BigQuery 的服务端代码模板（Tag Template）以及 BigQuery 中对应数据表的架构（Schema）。该代码模板能够将服务端 Google 代码管理器（sGTM, Server-Side Google Tag Manager）接收到的 GA4 数据近乎实时地自动写入 BigQuery。每条匹配的数据都会作为独立的一行写入 BigQuery，并支持批量事件（Batch Events）、Consent Mode v2（同意义见模式 v2）以及 Google Ads 广告归因等功能。


## 系统架构概览（集中式 GCP 项目架构）

您所有的 sGTM 代码植入服务器都以 **Cloud Run** 服务的形式运行在**同一个** GCP 项目中——每个 GTM 服务端容器对应一个 Cloud Run 服务。所有服务的数据统一写入**一个集中式 BigQuery 项目**，每个容器使用**独立的数据集 (Dataset)**。Cloud Run 项目与 BigQuery 项目可以是同一个项目，也可以是两个不同的项目——下方步骤对两种方案均适用。

这样可以避免"每个 GTM 容器一个 GCP 项目"带来的项目管理难题：统一结算、集中管理、IAM 权限简单清晰。

```
┌──────────────────────────────────────────────────────────────┐
│ 1. 客户端 / 浏览器 / App (gtag.js / GTM Web)                 │
└──────────────────────────────┬───────────────────────────────┘
                               │ HTTPS 请求 (GA4 hits)
                               ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. sGTM GCP 项目（所有代码植入服务器集中在一个项目中）       │
│                                                              │
│    Cloud Run 服务 "gtm-server-site1"  ← GTM 容器 1           │
│    Cloud Run 服务 "gtm-server-site2"  ← GTM 容器 2           │
│    Cloud Run 服务 "gtm-server-..."    ← 每个容器一个服务     │
└──────────────────────────────┬───────────────────────────────┘
                               │ BigQuery Streaming API
                               ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. 集中式 BigQuery 项目（可与上方项目为同一个项目）          │
│                                                              │
│    analytics_site1.events  ← 来自 gtm-server-site1 的数据    │
│    analytics_site2.events  ← 来自 gtm-server-site2 的数据    │
│    （每张表均按天分区与聚簇 Partitioned & Clustered）        │
└──────────────────────────────────────────────────────────────┘
```


## 前置条件与 GCP 权限要求

在开始配置前，请确保您对现有的 Google Cloud 项目具备相应访问权限：

### 1. 用户账号权限
用于部署 Cloud Run 服务以及运行 `deploy.sh` 创建 BigQuery 资源：
* **GCP 项目角色**：在所用项目上具备 **Editor (编辑者)** 或 **Owner (所有者)**（或具体包含 `roles/run.admin`、`roles/iam.serviceAccountUser` 以及 `roles/bigquery.admin` 权限）。

### 2. 服务账号权限（Cloud Run → BigQuery）

**若 Cloud Run 与 BigQuery 使用同一个 GCP 项目（最简单）：** 无需任何操作。Cloud Run 使用的默认 Compute Engine 服务账号（`<project-number>-compute@developer.gserviceaccount.com`）默认已具备 **Editor** 角色，开箱即用。

**若 BigQuery 位于另一个集中式项目中：** 只需执行一次以下授权。修改前 2 行后，将整段复制粘贴到 Cloud Shell 中运行：

```bash
SGTM_PROJECT_ID="my-sgtm-project"    # <-- 运行 sGTM Cloud Run 服务的项目 ID
BQ_PROJECT_ID="my-bigquery-project"  # <-- 集中式 BigQuery 项目 ID

PROJECT_NUMBER=$(gcloud projects describe "$SGTM_PROJECT_ID" --format="value(projectNumber)")
gcloud projects add-iam-policy-binding "$BQ_PROJECT_ID" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/bigquery.dataEditor"
gcloud projects add-iam-policy-binding "$BQ_PROJECT_ID" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/bigquery.jobUser"
```

> [!NOTE]
> 如果您的企业启用了严格的最小权限控制，仅需确保 Cloud Run 服务账号拥有以下两个权限：
> * **BigQuery Data Editor (BigQuery 数据编辑者)** (`roles/bigquery.dataEditor`)：在目标数据集（或 BigQuery 项目）上。
> * **BigQuery Job User (BigQuery 作业用户)** (`roles/bigquery.jobUser`)：在 BigQuery 项目上。


---


## 详细配置步骤（针对现有项目的手动部署）

### 步骤 1：从 GTM 中获取容器配置字符串 (Container Config)

1. 打开 [Google Tag Manager 控制台](https://tagmanager.google.com/)。
2. 创建一个新容器（或打开现有容器），目标平台选择 **Server (服务端)**。
3. 在弹出的初始配置窗口中，选择 **Manually provision tagging server (手动配置代码植入服务器)**。
4. 复制页面上显示的 **Container Config（容器配置字符串）**（一长串以 `aWQ9...` 开头的 Base64 字符串）。


### 步骤 2：在现有 GCP 项目中部署 Cloud Run 服务

在您的 GCP 控制台中打开 **Google Cloud Shell**（点击控制台右上角的 `>_` 终端图标）。

修改下方前 3 行后，将整段复制粘贴运行即可完成部署：

```bash
PROJECT_ID="my-sgtm-project"     # <-- 您的 GCP 项目 ID（集中承载所有 sGTM 服务器）
SERVICE_NAME="gtm-server-site1"  # <-- 为当前这个 GTM 容器取一个唯一的服务名称
CONTAINER_CONFIG="aWQ9..."       # <-- 步骤 1 中复制的容器配置字符串

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
> * **有多个 GTM 容器？** 换一个 `SERVICE_NAME`，填入对应容器自己的 `CONTAINER_CONFIG`，再运行一遍同样的命令块即可。所有服务都并存于同一个 GCP 项目中。
> * 可根据需要修改 `--region=us-central1`（例如 `europe-west1`、`asia-northeast1` 等）。

部署完成后，Cloud Run 终端将输出分配给该服务的 **Service URL**（例如 `https://gtm-server-xxxxxx-uc.a.run.app`）。

**将该 URL 绑定回 GTM**：
1. 回到 Google Tag Manager 控制台，进入 **管理 (Admin)** → **容器设置 (Container Settings)**。
2. 在 **服务端容器网址 (Server container URLs)** 下，点击 **添加网址 (Add URL)** 并粘贴刚才的 Cloud Run URL。
3. 点击 **保存 (Save)**。


### 步骤 3：创建 BigQuery 数据集与数据表

在同一个 **Google Cloud Shell** 终端中，运行自动化部署脚本：

```bash
rm -rf sgtm-ga4-to-bigquery && git clone https://github.com/cloudymoma/sgtm-ga4-to-bigquery.git && cd sgtm-ga4-to-bigquery && bash deploy.sh
```

该脚本将自动执行以下操作：
1. 提示输入您的 **GCP 项目 ID (Project ID)**。
2. 在该项目中启用 BigQuery API (`bigquery.googleapis.com`)。
3. 提示选择 **BigQuery 区域/位置 (Location/Region)**（例如 `US`、`EU`、`asia-northeast1`，默认 `US`）。
4. 提示输入 **数据集 ID (Dataset ID)**（例如 `analytics_site1`）与 **数据表 ID (Table ID)**（例如 `events`）。
5. 自动创建支持按天分区（Partitioning）并在 `event_name` 和 `ga_session_id` 上聚簇（Clustering）的数据表。

> [!TIP]
> * 当脚本询问 **GCP 项目 ID** 时，请输入您的**集中式 BigQuery 项目** ID——它可以与步骤 2 中部署 Cloud Run 的项目相同，也可以是另一个项目（若为不同项目，请先完成前置条件中的一次性授权）。
> * **有多个 GTM 容器？** 为每个容器各运行一次 `bash deploy.sh`，并为其分配独立的**数据集 ID**（例如 `analytics_site1`、`analytics_site2`）。所有数据集集中存放在同一个 BigQuery 项目中。


### 步骤 4：在 sGTM 中导入并配置代码模板

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
		* **Cloud Project ID**：步骤 3 中输入的 BigQuery 项目 ID。
		* **BigQuery Dataset ID**：步骤 3 中创建的数据集 ID（每个 GTM 容器使用自己独立的数据集）。
		* **BigQuery Table ID**：步骤 3 中创建的数据表 ID。
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


---


## 进阶指南：数据富化与增强（实时 ETL 与 ELT 方案）

若您希望在数据入库前后，结合自有业务数据库或 CRM 系统对 GA4 事件进行增强（例如根据 `user_id` 查询用户的 VIP 等级、历史累计消费金额或所属客户群体），有两种成熟的架构方案可供选择：

### 方案 A：实时管道内 ETL（服务端 GTM 实时增强）
在数据流式写入 BigQuery **之前**，在 sGTM 容器内部完成数据查询与拼装。

* **运作机制**：当事件到达 sGTM 时，代码模板通过内置 API 查询外部数据源，将查询到的字段追加到 `event_params` 或 `user_properties` 中，再一并写入 BigQuery。
  * **子方案 A1（Firestore API —— 键值查询推荐）**：使用 sGTM 内置的 `Firestore.read()` API 进行快速键值查询。要求 Firestore 为 **Native 模式**；既可读取同一 GCP 项目，也可通过 `projectId` 选项跨项目读取。
  * **子方案 A2（`sendHttpRequest` API —— 适用于 SQL / REST API）**：请求连接至 Cloud SQL/PostgreSQL/CRM 的 Cloud Function 或 REST API 微服务。
* **适用场景**：当**下游实时营销代码**（如 Google Ads 转化调整、Meta Conversions API）也需要在请求生命周期内**立即使用**富化后的用户数据时。

> [!IMPORTANT]
> sGTM 中的各个代码 (Tag) 相互独立运行，无法读取彼此的数据。如下方示例所示，**在本 BigQuery 代码内部**做富化，只会富化写入 BigQuery 的数据行。若希望其他代码（Meta CAPI、Google Ads）也能使用查询结果，应改为在自定义**变量 (Variable)** 模板中执行查询——服务端变量可以返回 Promise，所有引用该变量的代码都会获得解析后的值——或使用 GTM 的**转换 (Transformations)** 功能为指定代码增强事件数据。另请注意：沙盒化 Promise 超过 5 秒未完成会自动超时。

```javascript
// 示例：在自定义 sGTM 代码模板内部使用 REST API 进行实时数据富化。
// （eventRow、connectionInfo、options 与 data 均来自模板中已有的上下文代码。）
const sendHttpRequest = require('sendHttpRequest');
const encodeUriComponent = require('encodeUriComponent');
const JSON = require('JSON');
const BigQuery = require('BigQuery');

const apiUrl = 'https://api.example.com/crm/user?id=' + encodeUriComponent(eventRow.user_id);

sendHttpRequest(apiUrl, { method: 'GET', timeout: 1500 })
  .then((response) => {
    if (response.statusCode === 200) {
      const crmData = JSON.parse(response.body);
      eventRow.user_properties.push({
        key: 'vip_tier',
        value: { string_value: crmData.vip_tier }
      });
    }
    return BigQuery.insert(connectionInfo, [eventRow], options);
  })
  .then(() => data.gtmOnSuccess(), () => data.gtmOnFailure());
```

---

### 方案 B：下游 ELT 模式（BigQuery 库内关联增强 —— 分析场景推荐）
原始事件以零延迟直接写入 BigQuery，后续在数仓内部通过 SQL 进行关联转换。

* **运作机制**：sGTM 仅负责最快速地将原始事件写入 BigQuery，保证服务端零延迟、零外部依赖风险。BigQuery 中维护一张定期同步的 CRM/用户维表（如 `crm.users`）。通过 BigQuery 视图（View）、定时查询（Scheduled Query）或 dbt 模型通过 `user_id` 进行 `LEFT JOIN`。
* **适用场景**：数据富化主要用于 BI 报表（Looker / Looker Studio）、数据分析看板、机器学习与深度建模分析。

```sql
-- 示例：使用 BigQuery SQL 视图实现下游 ELT 数据增强
CREATE OR REPLACE VIEW `my-bigquery-project.analytics_site1.enriched_events` AS
SELECT
  e.*,
  u.vip_tier,
  u.registration_date,
  u.lifetime_value
FROM `my-bigquery-project.analytics_site1.events` e
LEFT JOIN `my-bigquery-project.crm.users` u
  ON e.user_id = u.user_id;
```

---

### 方案对比：实时 ETL 与下游 ELT

| 特性对比 | 方案 A：实时 ETL (sGTM 容器内) | 方案 B：下游 ELT (BigQuery 数仓内) |
| :--- | :--- | :--- |
| **数据增强位置** | sGTM 容器内部（BigQuery 写入前） | BigQuery 数据库内部（SQL 视图 / dbt） |
| **对服务端延迟影响** | 增加 5–50ms 网络查询耗时 | **0ms（最快速度流式写入）** |
| **故障 / 超时风险** | 外部 API 偶发故障可能影响代码执行 | **对线上实时数据流零干扰** |
| **下游广告代码共享** | **仅当查询在共享变量或 Transformations 中执行时**，Meta CAPI / Google Ads 才能共享富化数据 | 仅在 BigQuery / BI 报表内可用 |
| **最佳应用场景** | 实时广告竞价优化、实时受众同步 | 深度 BI 报表、业务分析看板、数据建模 |
