SELECT
    creationDate,
    editor.displayName,
    type.type          AS event_type,
    aggregate.id       AS aggregate_id,
    payload
FROM `${database_name}.zitadel_events`
WHERE year = '2026'
  AND month = '07'
  AND type.type LIKE 'user.%'
ORDER BY creationDate DESC;