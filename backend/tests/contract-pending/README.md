# Отложенные контрактные тесты

Эти файлы взяты из PR BasedHardware/omi#10887 и **не проходят на нашем форке** —
но не из-за слоя хранения, а потому что наш форк отстаёт от `upstream/main` на 247
коммитов и в наших версиях модулей ещё нет функций, которые эти тесты вызывают.

Проверено 23.08.2026, каждое падение разобрано:

| Файл | Чего не хватает у нас | Природа |
|---|---|---|
| `test_action_item_dedup_contract.py` | `action_items._existing_live_id_in_transaction` (upstream вынес inline-логику в хелпер); плюс новое поведение «снятая строка теряет ключ дедупликации» | дрейф upstream |
| `test_advice_contract.py` | `advice._MAX_MARK_READ_PAGES` | дрейф upstream |
| `test_fair_use_contract.py` | `fair_use.lookup_fair_use_event_by_case_ref` | дрейф upstream |
| `test_notifications_contract.py` | `notifications.get_users_endpoints_in_timezones`, `remove_bulk_endpoints` (появились вместе с UnifiedPush) | дрейф upstream + чужая подсистема |
| `test_referrals_contract.py` | наш реферальный грант выдаёт план `architect`, upstream переименовал в `operator` | дрейф upstream |

**Ни одного падения из-за Mongo или фасада здесь нет.** Вернуть в `tests/contract/`
когда догоним upstream по этим модулям.

Совсем удалены (тестируют подсистемы, которые мы сознательно не переносили —
`utils.auth` / Keycloak, `utils.object_store` / S3, `utils.vector` / Qdrant, локальный
инференс): `test_auth_provider_contract.py`, `test_object_store_contract.py`,
`test_vector_store_contract.py`, `test_onprem_search_roundtrip.py`,
`test_embeddings_live_contract.py`, `test_translation_nllb_live_contract.py`,
`test_speaker_embedding_live_contract.py`.
