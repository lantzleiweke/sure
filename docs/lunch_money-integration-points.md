# Lunch Money integration points

This checklist records the current Sure integration points for the approved
Lunch Money design. It is a source-map, not an instruction to duplicate every
nearby provider's behavior.

## Generator output versus manual additions

`Provider::FamilyGenerator` is authoritative for the generated surfaces below;
inspect its templates/output rather than treating this list as a replacement
for running the generator. Its `update_settings_controller` step generates
only the `prepare_show_context` item-assignment and item-exclusion logic in
`app/controllers/settings/providers_controller.rb`. It does **not** generate
the family panel or panel-sync registrations, or the panel item-loading
helpers.

### Generated-output verification checklist

Confirm the generator output includes all of these (and that generated
provider-specific names are correct):

- [ ] Migration for the provider item and account tables.
- [ ] Item and account models, including the family-connectable concern and
      Family inclusion/association.
- [ ] Family connectable concern, adapter, SDK, unlinking, syncer, importer,
      account DataHelpers, processors, cleanup job, and jobs.
- [ ] CRUD/resource controller.
- [ ] Item and panel views (including account-linking/setup views).
- [ ] Locales and generated tests.
- [ ] Settings, accounts, and providers view updates.
- [ ] Source enum updates in `app/models/provider_merchant.rb` and
      `app/models/data_enrichment.rb`.
- [ ] Generated `resources :lunch_money_items` routes, including account
      linking and sync/setup endpoints.

The generated resource routes are provider-specific and are **not** replaced
by the generic settings connect-form route. Verify both route families.

## Manual settings wiring checklist

Use the existing Lunch Flow entry in
`app/controllers/settings/providers_controller.rb` as the factual wiring
pattern, while using the approved `lunch_money` key and names. Manually verify:

- [ ] `FAMILY_PANELS` has `{ key: "lunch_money", title: "Lunch Money", turbo_id:
      "lunch_money", partial: "lunch_money_panel" }` (matching the existing
      Lunch Flow entry's required key/title/turbo-id/partial fields).
- [ ] `PANEL_SYNCABLE_TYPES` contains
      `"lunch_money" => "LunchMoneyItem"`.
- [ ] `load_provider_items` assigns
      `@lunch_money_items = Current.family.lunch_money_items.ordered` (with
      any approved, provider-specific scope/includes kept consistent with the
      generated model and panel needs).
- [ ] `prepare_show_context` loads the `@lunch_money_items` collection needed
      by the panel and excludes `lunch_money` from the configuration registry
      through `FAMILY_PANEL_KEYS`. The generator handles the provider-specific
      condition inside the registry rejection; adding the family-panel entry,
      key list's resulting behavior, and the item-loading wiring is manually
      verified.
- [ ] `family_panel_items` maps `"lunch_money" => @lunch_money_items`.
- [ ] The matching `lunch_money_panel` partial/view exists and follows the
      existing Lunch Flow panel render path, including the matching turbo id
      and provider-specific resource/controller links.

These generated outputs are distinct from the manual hardcoded registrations
and panel wiring described above.

## Routes

The settings provider connect form already has one generic route:
`get ":provider_key/connect_form"`. It is dispatched by
`Settings::ProvidersController#connect_form`; no provider-specific
connect-form route should be added.

Only genuinely provider-specific routes required by the generated controller
or resource belong in this checklist. The generic settings connect-form route
is not one of those additions.

## Current hardcoded provider registrations

Review the following existing registries and SQL dispatch branches when adding
a provider:

- `ProviderConnectionStatus::PROVIDERS`.
- `Provider::Metadata::REGISTRY`.
- `Transaction::PENDING_PROVIDERS`.
- The pending-metadata SQL branches in
  `Account::ProviderImportAdapter`.

For Lunch Money, the approved design is posted-only: pending transactions are
intentionally omitted. The integration checklist must make that omission
explicit wherever these pending-provider registrations are considered; it
must not imply pending support or invent pending behavior.

## Naming note

The existing Lunch Flow integration uses `Lunchflow`/`lunchflow`. The approved
Lunch Money naming is documented elsewhere and is not derived from the current
source naming.
