-- Registra a SERVICE_API_KEY do evaluation-service (gerada pelo
-- openbao-bootstrap.sh) sem precisar chamar POST /admin/keys à mão.
-- O auth-service guarda só o SHA-256 da chave (ver key.go), então é
-- o hash que entra na tabela. Idempotente: rodar de novo não duplica.
INSERT INTO api_keys (name, key_hash)
VALUES ('evaluation-service', encode(sha256(convert_to(:'api_key', 'UTF8')), 'hex'))
ON CONFLICT (key_hash) DO NOTHING;
