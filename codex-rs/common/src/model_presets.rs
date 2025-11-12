use codex_app_server_protocol::AuthMode;
use codex_core::default_client::create_client;
use codex_core::protocol_config_types::ReasoningEffort;
#[cfg(feature = "serde")]
use serde::Deserialize;

#[cfg_attr(feature = "serde", derive(Deserialize))]
struct ModelInfoResponse {
    #[allow(unused)]
    object: Option<String>,
    data: Vec<ModelInfo>,
}

#[cfg_attr(feature = "serde", derive(Deserialize))]
struct ModelInfoLiteLLMParams {
    #[allow(unused)]
    max_tokens: i64,
    model: String,
}

#[cfg_attr(feature = "serde", derive(Deserialize))]
struct ModelInfoParams {
    #[allow(unused)]
    banner: Option<String>,
    #[allow(unused)]
    context_window: i64,
    description: Option<String>,
    #[allow(unused)]
    labels: Option<String>,
    #[allow(unused)]
    survey_content: Option<String>,
    #[allow(unused)]
    survey_id: Option<String>,
    #[allow(unused)]
    version: Option<String>,
}

#[cfg_attr(feature = "serde", derive(Deserialize))]
struct ModelInfo {
    model_info: ModelInfoParams,
    model_name: String,
    litellm_params: ModelInfoLiteLLMParams,
}

/// A reasoning effort option that can be surfaced for a model.
#[derive(Debug, Clone, Copy)]
pub struct ReasoningEffortPreset {
    /// Effort level that the model supports.
    pub effort: ReasoningEffort,
    /// Short human description shown next to the effort in UIs.
    pub description: &'static str,
}

/// Metadata describing a Codex-supported model.
#[derive(Debug, Clone, Copy)]
pub struct ModelPreset {
    /// Stable identifier for the preset.
    pub id: &'static str,
    /// Model slug (e.g., "gpt-5").
    pub model: &'static str,
    /// Display name shown in UIs.
    pub display_name: &'static str,
    /// Short human description shown in UIs.
    pub description: &'static str,
    /// Reasoning effort applied when none is explicitly chosen.
    pub default_reasoning_effort: Option<ReasoningEffort>,
    /// Supported reasoning effort options.
    pub supported_reasoning_efforts: &'static [ReasoningEffortPreset],
    /// Whether this is the default model for new users.
    pub is_default: bool,
}

const PRESETS: &[ModelPreset] = &[
    ModelPreset {
        id: "gpt-5-codex",
        model: "gpt-5-codex",
        display_name: "gpt-5-codex",
        description: "Optimized for coding tasks with many tools.",
        default_reasoning_effort: Some(ReasoningEffort::Medium),
        supported_reasoning_efforts: &[
            ReasoningEffortPreset {
                effort: ReasoningEffort::Low,
                description: "Fastest responses with limited reasoning",
            },
            ReasoningEffortPreset {
                effort: ReasoningEffort::Medium,
                description: "Dynamically adjusts reasoning based on the task",
            },
            ReasoningEffortPreset {
                effort: ReasoningEffort::High,
                description: "Maximizes reasoning depth for complex or ambiguous problems",
            },
        ],
        is_default: true,
    },
    ModelPreset {
        id: "gpt-5",
        model: "gpt-5",
        display_name: "gpt-5",
        description: "Broad world knowledge with strong general reasoning.",
        default_reasoning_effort: Some(ReasoningEffort::Medium),
        supported_reasoning_efforts: &[
            ReasoningEffortPreset {
                effort: ReasoningEffort::Minimal,
                description: "Fastest responses with little reasoning",
            },
            ReasoningEffortPreset {
                effort: ReasoningEffort::Low,
                description: "Balances speed with some reasoning; useful for straightforward queries and short explanations",
            },
            ReasoningEffortPreset {
                effort: ReasoningEffort::Medium,
                description: "Provides a solid balance of reasoning depth and latency for general-purpose tasks",
            },
            ReasoningEffortPreset {
                effort: ReasoningEffort::High,
                description: "Maximizes reasoning depth for complex or ambiguous problems",
            },
        ],
        is_default: false,
    },
];

/// Synchronous version that returns static presets for non-OCA auth modes.
/// For OCA auth mode, this will panic - use the async version instead.
pub fn builtin_model_presets_sync(_auth_mode: Option<AuthMode>) -> Vec<ModelPreset> {
    if _auth_mode == Some(AuthMode::OCA) {
        panic!("OCA auth mode requires async builtin_model_presets function");
    }
    PRESETS.to_vec()
}

pub async fn builtin_model_presets(
    _auth_mode: Option<AuthMode>,
    base_url: Option<&str>,
    access_token: Option<&str>,
) -> Result<Vec<ModelPreset>, Box<dyn std::error::Error + Send + Sync>> {
    if _auth_mode == Some(AuthMode::OCA) {
        // For now, return static presets. The async version would be called from async contexts.
        return fetch_oracle_code_assist_models(
            base_url.unwrap_or_default(),
            access_token.unwrap_or_default(),
        )
        .await;
    }
    Ok(PRESETS.to_vec())
}

pub async fn fetch_oracle_code_assist_models(
    base_url: &str,
    access_token: &str,
) -> Result<Vec<ModelPreset>, Box<dyn std::error::Error + Send + Sync>> {
    let client = create_client();
    let url = format!("{}/v1/model/info", base_url.trim_end_matches('/'));

    let response = client.get(&url).bearer_auth(access_token).send().await?;

    if !response.status().is_success() {
        return Err(format!("API request failed with status: {}", response.status()).into());
    }

    let response_data = response.json::<ModelInfoResponse>().await?;
    let mut presets = Vec::new();

    let mut is_default = true;

    for model_info in response_data.data {
        // Create static versions for the struct
        let id = Box::leak(model_info.litellm_params.model.clone().into_boxed_str());
        let model = Box::leak(model_info.litellm_params.model.clone().into_boxed_str());
        let display_name = Box::leak(model_info.model_name.into_boxed_str());
        let description = Box::leak(
            model_info
                .model_info
                .description
                .unwrap_or_default()
                .into_boxed_str(),
        );

        let preset = ModelPreset {
            id,
            model,
            display_name,
            description,
            default_reasoning_effort: None,
            supported_reasoning_efforts: Box::leak(Vec::new().into_boxed_slice()),
            is_default,
        };
        is_default = false;

        presets.push(preset);
    }

    Ok(presets)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_one_default_model_is_configured() {
        let default_models = PRESETS.iter().filter(|preset| preset.is_default).count();
        assert!(default_models == 1);
    }
}
