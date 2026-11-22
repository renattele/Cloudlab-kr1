terraform {
  required_version = ">= 1.8"
  required_providers {
    yandex  = { source = "yandex-cloud/yandex", version = "~> 0.250" }
    archive = { source = "hashicorp/archive", version = "~> 2.7" }
    time    = { source = "hashicorp/time", version = "~> 0.13" }
    restful = { source = "magodo/restful" }
    env     = { source = "marcozac/env" }
  }
}

# Аутентификация — IAM-токен из переменной окружения YC_TOKEN.
provider "yandex" {
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
}

# Document API YDB для создания документной таблицы без shell-скриптов.
provider "restful" {
  base_url = "https://docapi.serverless.yandexcloud.net"
  header = {
    Authorization = "Bearer ${provider::env::getenv("YC_TOKEN", false)}"
    Content-Type  = "application/x-amz-json-1.0"
    X-Amz-Target  = "DynamoDB_20120810.CreateTable"
  }
  client = {
    retry = {
      status_codes    = [429, 500, 502, 503, 504]
      count           = 20
      wait_in_sec     = 2
      max_wait_in_sec = 5
    }
  }
}

locals {
  table  = "archives"
  prefix = try(regex("^(vvot[0-9]{2})-", var.bucket_name)[0], "vvot12")
}

# ---------- Сервисный аккаунт и роли ----------

resource "yandex_iam_service_account" "sa" {
  name = "${local.prefix}-sa"
}

resource "yandex_resourcemanager_folder_iam_member" "sa" {
  for_each  = toset(["ymq.admin", "storage.editor", "ydb.editor", "functions.functionInvoker"])
  folder_id = var.folder_id
  role      = each.value
  member    = "serviceAccount:${yandex_iam_service_account.sa.id}"
}

resource "yandex_iam_service_account_static_access_key" "sa" {
  service_account_id = yandex_iam_service_account.sa.id
}

# Новым ролям и статическому ключу нужно время, чтобы начать действовать.
resource "time_sleep" "iam_ready" {
  depends_on      = [yandex_resourcemanager_folder_iam_member.sa, yandex_iam_service_account_static_access_key.sa]
  create_duration = "15s"
}

# ---------- Хранилище файлов ----------

resource "yandex_storage_bucket" "archives" {
  bucket        = var.bucket_name
  folder_id     = var.folder_id
  max_size      = 10 * 1024 * 1024 * 1024 # 10 ГБ
  force_destroy = true

  # Доступ только с авторизацией.
  anonymous_access_flags {
    read        = false
    list        = false
    config_read = false
  }
}

# ---------- База данных ----------

resource "yandex_ydb_database_serverless" "db" {
  name = "${local.prefix}-db"

  serverless_database {
    enable_throttling_rcu_limit = true
    throttling_rcu_limit        = 10 # RU/с
    storage_size_limit          = 1  # ГБ
  }
}

# Документная таблица создаётся через YDB Document API тем же IAM-токеном (YC_TOKEN).
resource "restful_operation" "archives_table" {
  path   = yandex_ydb_database_serverless.db.database_path
  method = "POST"
  body = {
    TableName            = local.table
    AttributeDefinitions = [{ AttributeName = "key", AttributeType = "S" }]
    KeySchema            = [{ AttributeName = "key", KeyType = "HASH" }]
    BillingMode          = "PAY_PER_REQUEST"
  }
}

# ---------- Очереди ----------

resource "yandex_message_queue" "dead_letter_queue" {
  depends_on                = [time_sleep.iam_ready]
  name                      = "${local.prefix}-dead-letter-queue"
  message_retention_seconds = 14 * 24 * 3600
  access_key                = yandex_iam_service_account_static_access_key.sa.access_key
  secret_key                = yandex_iam_service_account_static_access_key.sa.secret_key
}

resource "yandex_message_queue" "tasks" {
  name                       = "${local.prefix}-tasks"
  visibility_timeout_seconds = 900
  receive_wait_time_seconds  = 20
  message_retention_seconds  = 24 * 3600
  redrive_policy = jsonencode({
    deadLetterTargetArn = yandex_message_queue.dead_letter_queue.arn
    maxReceiveCount     = 1
  })
  access_key = yandex_iam_service_account_static_access_key.sa.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa.secret_key
}

# ---------- Функция архивирования и триггер ----------

data "archive_file" "function" {
  type        = "zip"
  source_dir  = "${path.module}/function"
  excludes    = ["__pycache__"]
  output_path = "${path.module}/build/function.zip"
}

resource "yandex_function" "archiver" {
  name               = "${local.prefix}-archiver"
  runtime            = "python312"
  entrypoint         = "index.handler"
  memory             = 256
  execution_timeout  = "600"
  service_account_id = yandex_iam_service_account.sa.id
  user_hash          = data.archive_file.function.output_sha256

  environment = {
    BUCKET                = yandex_storage_bucket.archives.bucket
    TABLE                 = local.table
    DOCAPI_ENDPOINT       = yandex_ydb_database_serverless.db.document_api_endpoint
    AWS_ACCESS_KEY_ID     = yandex_iam_service_account_static_access_key.sa.access_key
    AWS_SECRET_ACCESS_KEY = yandex_iam_service_account_static_access_key.sa.secret_key
    AWS_DEFAULT_REGION    = "ru-central1"
  }

  content {
    zip_filename = data.archive_file.function.output_path
  }
}

resource "yandex_function_trigger" "tasks" {
  name       = "${local.prefix}-tasks-trigger"
  depends_on = [time_sleep.iam_ready]

  message_queue {
    queue_id           = yandex_message_queue.tasks.arn
    service_account_id = yandex_iam_service_account.sa.id
    batch_size         = "1"
    batch_cutoff       = "0"
  }

  function {
    id                 = yandex_function.archiver.id
    service_account_id = yandex_iam_service_account.sa.id
  }
}

# ---------- API-шлюз ----------

resource "yandex_api_gateway" "api" {
  depends_on = [restful_operation.archives_table, time_sleep.iam_ready]
  name       = "${local.prefix}-api"
  spec = templatefile("${path.module}/openapi.yaml", {
    prefix             = local.prefix
    folder_id          = var.folder_id
    queue_url          = yandex_message_queue.tasks.id
    database           = yandex_ydb_database_serverless.db.database_path
    table              = local.table
    bucket             = yandex_storage_bucket.archives.bucket
    service_account_id = yandex_iam_service_account.sa.id
  })
}
