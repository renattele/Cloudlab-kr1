output "api_url" {
  description = "Служебный домен API-шлюза — точка входа клиента"
  value       = "https://${yandex_api_gateway.api.domain}"
}
