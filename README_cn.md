[English](README.md) | [简体中文](README_cn.md)

## Google Analytics 4 (GA4) 至 BigQuery 代码模板 (Tag Template)

这不是 Google 官方支持的产品。


## 概述

本代码仓库包含 GA4 至 BigQuery 的服务端代码模板（Tag Template）以及 BigQuery 中对应数据表的架构（Schema）。该代码模板能够将服务端 Google 代码管理器（sGTM, Server-Side Google Tag Manager）接收到的 GA4 数据近乎实时地自动写入 BigQuery。每条匹配的数据都会作为独立的一行写入 BigQuery，并支持批量事件（Batch Events）、Consent Mode v2（同意义见模式 v2）以及 Google Ads 广告归因等功能。


## BigQuery 数据表配置

为了使数据能够成功写入 BigQuery，必须先创建一个具有正确架构的 BigQuery 数据表。请在 Google Cloud Shell 中运行以下命令，使用 `deploy.sh` 脚本自动完成数据集和数据表（支持按天分区与聚簇）的创建：

```bash
rm -rf sgtm-ga4-to-bigquery && git clone https://github.com/cloudymoma/sgtm-ga4-to-bigquery.git && cd sgtm-ga4-to-bigquery && bash deploy.sh
```


## 代码模板配置

1. 将 `template.tpl` 文件作为自定义代码模板导入到您的 sGTM 服务端容器中：
	* 下载 `template.tpl` 文件到本地。
	* 打开您的 GTM 服务端容器工作区。
	* 进入 **模板 (Templates)**。
	* 在 **代码模板 (Tag Templates)** 下点击 **新建 (New)**。
	* 点击右上角的三个点菜单（更多操作），选择 **导入 (Import)**。
	* 选择 `template.tpl` 文件并点击 **保存 (Save)**。
2. 进入 **代码 (Tags)**，点击 **新建 (New)**，点击 **代码配置 (Tag Configuration)**，在“自定义 (Custom)”下选择 **GA4 to BigQuery**。
3. 输入代码所需的配置项（Cloud Project ID、Dataset ID 和 Table ID）。
4. 设置代码的触发条件 (Trigger)：
    1. 创建一个新的 **自定义 (Custom)** 触发器。
    2. 将触发器设置为在所有事件（或特定 GA4 事件）发生时触发。
    3. 命名该触发器。
    4. 保存触发器。
5. 保存该代码 (Tag)。
6. 发布新的容器版本。


## 模板字段说明

*   **Measurement ID（衡量 ID）**
    *   输入需要写入 BigQuery 的数据流衡量 ID（例如 `G-XXXXXXXXXX`），或者输入 `*` 匹配所有衡量 ID。默认值为 `*`。
*   **Write IP Address to BigQuery（写入 IP 地址）**
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
