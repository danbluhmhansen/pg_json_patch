use pgrx::{Json, JsonB, prelude::*};
use thiserror::Error;

::pgrx::pg_module_magic!(name, version);

#[pg_extern]
fn json_diff(left: Json, right: Json) -> serde_json::Result<Json> {
    serde_json::to_value(json_patch::diff(&left.0, &right.0)).map(Json)
}

#[pg_extern]
fn jsonb_diff(left: JsonB, right: JsonB) -> serde_json::Result<JsonB> {
    serde_json::to_value(json_patch::diff(&left.0, &right.0)).map(JsonB)
}

#[pg_extern]
fn json_patch(mut doc: Json, patch: Json) -> Result<Json, JsonPatchError> {
    json_patch::patch(
        &mut doc.0,
        &serde_json::from_value::<json_patch::Patch>(patch.0)?,
    )?;
    Ok(doc)
}

#[pg_extern]
fn jsonb_patch(mut doc: JsonB, patch: JsonB) -> Result<JsonB, JsonPatchError> {
    json_patch::patch(
        &mut doc.0,
        &serde_json::from_value::<json_patch::Patch>(patch.0)?,
    )?;
    Ok(doc)
}

#[pg_extern]
fn json_merge(mut doc: Json, patch: Json) -> Json {
    json_patch::merge(&mut doc.0, &patch.0);
    doc
}

#[pg_extern]
fn jsonb_merge(mut doc: JsonB, patch: JsonB) -> JsonB {
    json_patch::merge(&mut doc.0, &patch.0);
    doc
}

extension_sql!(
    "CREATE AGGREGATE json_patch_agg(json) (
    SFUNC    = json_patch,
    STYPE    = json,
    INITCOND = '{}'
);",
    name = "json_patch_agg",
    requires = [json_patch]
);

extension_sql!(
    "CREATE AGGREGATE jsonb_patch_agg(jsonb) (
    SFUNC    = jsonb_patch,
    STYPE    = jsonb,
    INITCOND = '{}'
);",
    name = "jsonb_patch_agg",
    requires = [jsonb_patch]
);

extension_sql!(
    "CREATE AGGREGATE json_merge_agg(json) (
    SFUNC    = json_merge,
    STYPE    = json,
    INITCOND = '{}'
);",
    name = "json_merge_agg",
    requires = [json_merge]
);

extension_sql!(
    "CREATE AGGREGATE jsonb_merge_agg(jsonb) (
    SFUNC    = jsonb_merge,
    STYPE    = jsonb,
    INITCOND = '{}'
);",
    name = "jsonb_merge_agg",
    requires = [jsonb_merge]
);

#[derive(Debug, Error)]
#[error(transparent)]
enum JsonPatchError {
    JsonPatch(#[from] json_patch::PatchError),
    SerdeJson(#[from] serde_json::Error),
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use std::error::Error;

    use pgrx::{JsonB, prelude::*};

    #[pg_test]
    fn diff() -> Result<(), Box<dyn Error>> {
        let left = serde_json::json!({
            "title": "Goodbye!",
            "author": {
                "givenName": "John",
                "familyName": "Doe"
            },
            "tags": ["example", "sample"],
            "content": "This will be unchanged",
        });

        let right = serde_json::json!({
            "title": "Hello!",
            "author": {
                "givenName": "John"
            },
            "tags": ["example"],
            "content": "This will be unchanged",
            "phoneNumber": "+01-123-456-7890",
        });

        let patch = super::jsonb_diff(JsonB(left), JsonB(right))?;
        assert_eq!(
            patch.0,
            serde_json::json!([
              { "op": "remove", "path": "/author/familyName" },
              { "op": "add", "path": "/phoneNumber", "value": "+01-123-456-7890" },
              { "op": "remove", "path": "/tags/1" },
              { "op": "replace", "path": "/title", "value": "Hello!" },
            ])
        );

        Ok(())
    }
}

/// This module is required by `cargo pgrx test` invocations.
/// It must be visible at the root of your extension crate.
#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {
        // perform one-off initialization when the pg_test framework starts
    }

    #[must_use]
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        // return any postgresql.conf settings that are required for your tests
        vec![]
    }
}
