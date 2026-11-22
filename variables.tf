variable "cloud_id" {
  description = "Идентификатор облака Yandex Cloud"
  type        = string
}

variable "folder_id" {
  description = "Идентификатор каталога, в котором создаются ресурсы"
  type        = string
}

variable "bucket_name" {
  description = "Имя бакета для ZIP-архивов, например vvot12-archives или vvot00-archives"
  type        = string
}
