uniffi::setup_scaffolding!();

use std::collections::{BTreeMap, HashMap};
use std::sync::OnceLock;
use std::time::Duration;

use opentelemetry::trace::TracerProvider as _;
use opentelemetry::KeyValue;
use opentelemetry_otlp::{SpanExporter, WithExportConfig};
use opentelemetry_sdk::trace::SdkTracerProvider;
use opentelemetry_sdk::Resource;
use rig::completion::message::{CallId, ToolChoice, ToolName};
use rig::completion::{
    AssistantContent, AssistantMessage, CompletionRequest, Message,
};
use rig::providers::openai::{OpenAI, OpenAIConfig};
use rig::typesafeai::types::{Question, Usage};
use rig::typesafeai::{DynamicQuery, Evaluate, JevConfig, Noul, Query};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tracing::Instrument;
use tracing_opentelemetry::OpenTelemetryLayer;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::EnvFilter;

static TRACER_PROVIDER: OnceLock<SdkTracerProvider> = OnceLock::new();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RigError {
    #[error("config: {message}")]
    Config { message: String },
    #[error("llm: {message}")]
    Llm { message: String },
    #[error("jev: {message}")]
    Jev { message: String },
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct JevDecision {
    pub question_id: String,
    /// Probability of "yes" reported by Jev. Threshold policy belongs to the caller.
    pub probability: f64,
    pub model: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ChatText {
    pub text: String,
    pub model: String,
}

#[derive(Debug, Clone, Serialize, uniffi::Record)]
pub struct ToolCallOut {
    pub id: String,
    pub name: String,
    pub arguments: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ChatOut {
    pub content: Option<String>,
    pub tool_calls: Vec<ToolCallOut>,
    pub model: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct JevDynamicResult {
    pub answers_json: String,
    pub model: String,
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
    pub request_id: Option<String>,
}

/// Per-call provider configuration. Passed as JSON so there is no global mutable state:
/// multiple app settings and tests can run against different providers concurrently.
#[derive(Clone, Deserialize)]
struct RigConfig {
    base_url: String,
    api_key: String,
    model: String,
    max_tokens: u64,
    timeout_s: f64,
    embed_base_url: String,
    embed_api_key: String,
    embed_model: String,
    jev_base_url: String,
    jev_enabled: bool,
    jev_model: String,
    jev_timeout_s: f64,
    jev_api_key: Option<String>,
}

impl RigConfig {
    fn from_json(config_json: &str) -> Result<Self, RigError> {
        serde_json::from_str(config_json)
            .map_err(|e| config_error(format!("config JSON: {e}")))
    }

    /// PoC env-backed config, preserving the original `RIG_POC_*` behavior.
    fn from_env() -> Result<Self, RigError> {
        Ok(Self {
            base_url: std::env::var("RIG_POC_BASE_URL")
                .unwrap_or_else(|_| "https://api.commandcode.ai/provider/v1".into()),
            api_key: std::env::var("CMD_API_KEY").unwrap_or_default(),
            model: std::env::var("RIG_POC_MODEL")
                .unwrap_or_else(|_| "xiaomi/mimo-v2.6-flash".into()),
            max_tokens: std::env::var("RIG_POC_MAX_TOKENS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(8192),
            timeout_s: std::env::var("RIG_POC_TIMEOUT_S")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(120.0),
            embed_base_url: std::env::var("RIG_POC_EMBED_BASE_URL")
                .unwrap_or_else(|_| "https://openrouter.ai/api/v1".into()),
            embed_api_key: std::env::var("OPENROUTER_API_KEY").unwrap_or_default(),
            embed_model: std::env::var("RIG_POC_EMBED_MODEL")
                .unwrap_or_else(|_| "baai/bge-base-en-v1.5".into()),
            jev_base_url: std::env::var("RIG_POC_JEV_ENDPOINT")
                .unwrap_or_else(|_| "https://api.commandcode.ai/provider/v1/systemone".into()),
            jev_enabled: true,
            jev_model: std::env::var("RIG_POC_JEV_MODEL")
                .unwrap_or_else(|_| "typesafe/jev-1.14.0".into()),
            jev_timeout_s: std::env::var("RIG_POC_JEV_TIMEOUT_S")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(120.0),
            jev_api_key: std::env::var("JEV_TOKEN").ok(),
        })
    }
}

/// Clamp a configured timeout to something `Duration::from_secs_f64` accepts.
fn timeout_seconds(value: f64, fallback: f64) -> f64 {
    if value.is_finite() && value > 0.0 {
        value
    } else {
        fallback
    }
}

#[derive(Debug, Deserialize)]
struct InMessage {
    role: String,
    #[serde(default)]
    content: Option<String>,
    #[serde(default)]
    tool_calls: Vec<InToolCall>,
    #[serde(default)]
    tool_call_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct InToolCall {
    id: String,
    function: InFunction,
}

#[derive(Debug, Deserialize)]
struct InFunction {
    name: String,
    #[serde(default)]
    arguments: String,
}

#[derive(Debug, Deserialize)]
struct InTool {
    function: InToolDefinition,
}

#[derive(Debug, Deserialize)]
struct InToolDefinition {
    name: String,
    #[serde(default)]
    description: String,
    #[serde(default = "empty_schema")]
    parameters: Value,
}

fn empty_schema() -> Value {
    json!({"type": "object", "properties": {}})
}

fn config_error(message: impl Into<String>) -> RigError {
    RigError::Config { message: message.into() }
}

fn llm_error(error: impl std::fmt::Display) -> RigError {
    RigError::Llm { message: error.to_string() }
}

fn jev_error(error: impl std::fmt::Display) -> RigError {
    RigError::Jev { message: error.to_string() }
}

fn chat_client(config: &RigConfig) -> Result<OpenAI, RigError> {
    if config.api_key.is_empty() {
        return Err(config_error("CMD_API_KEY is not set"));
    }
    Ok(OpenAIConfig::new(config.api_key.clone())
        .with_base_url(config.base_url.clone())
        .client())
}

fn parse_messages(messages_json: &str) -> Result<Vec<Message>, RigError> {
    let input: Vec<InMessage> = serde_json::from_str(messages_json)
        .map_err(|e| config_error(format!("messages JSON: {e}")))?;
    if input.is_empty() {
        return Err(config_error("messages cannot be empty"));
    }
    let mut tool_names: HashMap<String, String> = HashMap::new();
    let mut messages = Vec::with_capacity(input.len());
    for message in input {
        match message.role.as_str() {
            "system" => messages.push(Message::system(message.content.unwrap_or_default())),
            "user" => messages.push(Message::user(message.content.unwrap_or_default())),
            "assistant" => {
                let mut content = Vec::new();
                if let Some(text) = message.content {
                    if !text.is_empty() {
                        content.push(AssistantContent::text(text));
                    }
                }
                for call in message.tool_calls {
                    tool_names.insert(call.id.clone(), call.function.name.clone());
                    let name = ToolName::new(call.function.name)
                        .map_err(|e| config_error(format!("tool name: {e}")))?;
                    let arguments = serde_json::from_str(&call.function.arguments)
                        .unwrap_or_else(|_| json!({}));
                    content.push(AssistantContent::tool_call(call.id, name, arguments));
                }
                messages.push(Message::Assistant(AssistantMessage::new(content)));
            }
            "tool" => {
                let id = message.tool_call_id.unwrap_or_default();
                let name = tool_names.get(&id).cloned().unwrap_or_else(|| "tool".into());
                let name = ToolName::new(name)
                    .map_err(|e| config_error(format!("tool name: {e}")))?;
                messages.push(Message::tool_result(
                    CallId::from_wire(id),
                    name,
                    message.content.unwrap_or_default(),
                ));
            }
            _ => messages.push(Message::user(message.content.unwrap_or_default())),
        }
    }
    Ok(messages)
}

fn parse_tools(tools_json: &str) -> Result<Vec<rig::completion::ToolDefinition>, RigError> {
    if tools_json.trim().is_empty() || tools_json.trim() == "null" {
        return Ok(Vec::new());
    }
    let input: Vec<InTool> = serde_json::from_str(tools_json)
        .map_err(|e| config_error(format!("tools JSON: {e}")))?;
    input
        .into_iter()
        .map(|tool| {
            let name = ToolName::new(tool.function.name)
                .map_err(|e| config_error(format!("tool name: {e}")))?;
            Ok(rig::completion::ToolDefinition::new(
                name,
                tool.function.description,
                tool.function.parameters,
            ))
        })
        .collect()
}

/// Configure Rig's tracing subscriber once. Rig emits `gen_ai.*` spans when a model call runs.
/// If `RIG_POC_OTLP_ENDPOINT` or `OTEL_EXPORTER_OTLP_ENDPOINT` is set, spans also export over
/// OTLP/HTTP (Phoenix accepts the endpoint directly).
#[uniffi::export]
pub fn init_tracing() {
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("rig=info,rig_poc=info"));
    let endpoint = std::env::var("RIG_POC_OTLP_ENDPOINT")
        .or_else(|_| std::env::var("OTEL_EXPORTER_OTLP_ENDPOINT"))
        .ok()
        .filter(|endpoint| !endpoint.trim().is_empty());
    let service_name = std::env::var("OTEL_SERVICE_NAME")
        .unwrap_or_else(|_| "rig-swift-poc".into());

    if let Some(endpoint) = endpoint {
        match otlp_provider(&endpoint, &service_name) {
            Ok(provider) => {
                let tracer = provider.tracer("rig_poc");
                let _ = TRACER_PROVIDER.set(provider);
                let otel = OpenTelemetryLayer::new(tracer);
                let _ = tracing_subscriber::registry()
                    .with(filter)
                    .with(otel)
                    .with(
                        tracing_subscriber::fmt::layer()
                            .with_target(true)
                            .with_writer(std::io::stderr),
                    )
                    .try_init();
                return;
            }
            Err(error) => {
                eprintln!("[rig_poc] OTLP setup failed for {endpoint}: {error}");
            }
        }
    }

    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(true)
        .try_init();
}

fn otlp_provider(endpoint: &str, service_name: &str) -> Result<SdkTracerProvider, String> {
    let project = std::env::var("PHOENIX_PROJECT")
        .ok()
        .filter(|project| !project.trim().is_empty())
        .unwrap_or_else(|| "food".into());
    let exporter = SpanExporter::builder()
        .with_http()
        .with_endpoint(endpoint)
        .build()
        .map_err(|error| error.to_string())?;
    Ok(SdkTracerProvider::builder()
        // Export on span end. This avoids needing a Tokio reactor on the batch thread and
        // guarantees a short-lived process flushes before exit.
        .with_simple_exporter(exporter)
        .with_resource(
            Resource::builder()
                .with_service_name(service_name.to_string())
                // Phoenix groups traces by this attribute; match the Python pipeline's project.
                .with_attribute(KeyValue::new("openinference.project.name", project))
                .build(),
        )
        .build())
}

/// Flush and shut down the OTLP exporter. Call before a short-lived process exits.
#[uniffi::export]
pub fn shutdown_tracing() {
    if let Some(provider) = TRACER_PROVIDER.get() {
        let _ = provider.shutdown();
    }
}

/// Plain text completion, the equivalent of `LLMProvider.chatText`.
#[uniffi::export(async_runtime = "tokio")]
pub async fn chat(prompt: String) -> Result<String, RigError> {
    Ok(chat_text(prompt).await?.text)
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn chat_text(prompt: String) -> Result<ChatText, RigError> {
    complete_text(RigConfig::from_env()?, None, prompt, 0.2).await
}

/// System/user completion returning raw text, the equivalent of `chatJSON`.
#[uniffi::export(async_runtime = "tokio")]
pub async fn chat_json(
    system: String,
    user: String,
    temperature: f64,
) -> Result<ChatText, RigError> {
    complete_text(RigConfig::from_env()?, Some(system), user, temperature).await
}

/// System/user completion with an explicit per-call config (`chatJSON`).
#[uniffi::export(async_runtime = "tokio")]
pub async fn chat_json_configured(
    config_json: String,
    system: String,
    user: String,
    temperature: f64,
) -> Result<ChatText, RigError> {
    complete_text(RigConfig::from_json(&config_json)?, Some(system), user, temperature).await
}

/// System/user text completion with an explicit per-call config (`chatText`).
#[uniffi::export(async_runtime = "tokio")]
pub async fn chat_text_configured(
    config_json: String,
    system: String,
    user: String,
    temperature: f64,
) -> Result<ChatText, RigError> {
    complete_text(RigConfig::from_json(&config_json)?, Some(system), user, temperature).await
}

async fn complete_text(
    config: RigConfig,
    system: Option<String>,
    user: String,
    temperature: f64,
) -> Result<ChatText, RigError> {
    let client = chat_client(&config)?;
    let model_id = config.model.clone();
    let input_json = json!({
        "system": system.as_deref(),
        "user": user.as_str(),
        "temperature": temperature,
    })
    .to_string();
    let span = rig::completion_parent_span!(
        target: "rig_poc",
        name: "chat",
        operation: "chat",
        system_instructions: Option::<&str>::None,
        input.value = %input_json,
        input.mime_type = "application/json",
        output.value = tracing::field::Empty,
        output.mime_type = "application/json",
        openinference.span.kind = "LLM",
        llm.provider = "openai",
        llm.model_name = %model_id,
    );
    let mut request = CompletionRequest::new(user)
        .temperature(Some(temperature))
        .max_tokens(Some(config.max_tokens))
        .record_content_telemetry(true);
    if let Some(system) = system {
        request = request.preamble(system);
    }
    let timeout = timeout_seconds(config.timeout_s, 120.0);
    let response = tokio::time::timeout(
        Duration::from_secs_f64(timeout),
        client
            .completion(model_id)
            .call(request)
            .instrument(span.clone()),
    )
    .await
    .map_err(|_| RigError::Llm {
        message: format!("timed out after {timeout}s"),
    })?
    .map_err(llm_error)?;
    let text = response.text();
    span.record("output.value", text.as_str());
    Ok(ChatText {
        text,
        model: response.model().unwrap_or("unknown").to_string(),
    })
}

/// Tool-calling chat, including forced `tool_choice`, the equivalent of
/// `LLMProvider.chat(messages:tools:forceTool:)`.
#[uniffi::export(async_runtime = "tokio")]
pub async fn chat_with_tools(
    messages_json: String,
    tools_json: String,
    force_tool: Option<String>,
    temperature: f64,
) -> Result<ChatOut, RigError> {
    chat_with_tools_impl(
        RigConfig::from_env()?,
        messages_json,
        tools_json,
        force_tool,
        temperature,
    )
    .await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn chat_with_tools_configured(
    config_json: String,
    messages_json: String,
    tools_json: String,
    force_tool: Option<String>,
    temperature: f64,
) -> Result<ChatOut, RigError> {
    chat_with_tools_impl(
        RigConfig::from_json(&config_json)?,
        messages_json,
        tools_json,
        force_tool,
        temperature,
    )
    .await
}

async fn chat_with_tools_impl(
    config: RigConfig,
    messages_json: String,
    tools_json: String,
    force_tool: Option<String>,
    temperature: f64,
) -> Result<ChatOut, RigError> {
    let client = chat_client(&config)?;
    let model_id = config.model.clone();
    let input_value = json!({
        "messages": serde_json::from_str::<Value>(&messages_json).unwrap_or(Value::Null),
        "tools": serde_json::from_str::<Value>(&tools_json).unwrap_or(Value::Null),
        "force_tool": force_tool.clone(),
        "temperature": temperature,
    });
    let input_json = input_value.to_string();
    let span = rig::completion_parent_span!(
        target: "rig_poc",
        name: "chat",
        operation: "chat",
        system_instructions: Option::<&str>::None,
        input.value = %input_json,
        input.mime_type = "application/json",
        output.value = tracing::field::Empty,
        output.mime_type = "application/json",
        openinference.span.kind = "LLM",
        llm.provider = "openai",
        llm.model_name = %model_id,
    );
    let mut messages = parse_messages(&messages_json)?;
    let tools = parse_tools(&tools_json)?;
    let last = messages.pop().ok_or_else(|| config_error("messages cannot be empty"))?;
    let mut request = CompletionRequest::new(last)
        .temperature(Some(temperature))
        .max_tokens(Some(config.max_tokens))
        .record_content_telemetry(true);
    if !messages.is_empty() {
        request = request.messages(messages);
    }
    if !tools.is_empty() {
        request = request.tools(tools);
    }
    if let Some(name) = force_tool {
        let name = ToolName::new(name)
            .map_err(|e| config_error(format!("forced tool name: {e}")))?;
        request = request.tool_choice(ToolChoice::Specific {
            function_names: vec![name],
        });
    }
    let timeout = timeout_seconds(config.timeout_s, 120.0);
    let response = tokio::time::timeout(
        Duration::from_secs_f64(timeout),
        client
            .completion(model_id)
            .call(request)
            .instrument(span.clone()),
    )
    .await
    .map_err(|_| RigError::Llm {
        message: format!("timed out after {timeout}s"),
    })?
    .map_err(llm_error)?;
    let calls: Vec<ToolCallOut> = response
        .tool_calls()
        .map(|call| ToolCallOut {
            id: call.id.to_string(),
            name: call.function.name.to_string(),
            arguments: serde_json::to_string(&call.function.arguments)
                .unwrap_or_else(|_| "{}".into()),
        })
        .collect();
    let content = Some(response.text()).filter(|text| !text.is_empty());
    let output_json = json!({
        "content": content,
        "tool_calls": calls.clone(),
    })
    .to_string();
    span.record("output.value", output_json.as_str());
    Ok(ChatOut {
        content,
        tool_calls: calls,
        model: response.model().unwrap_or("unknown").to_string(),
    })
}

/// OpenRouter embeddings, the equivalent of `LLMProvider.embed`.
#[uniffi::export(async_runtime = "tokio")]
pub async fn embed(texts: Vec<String>) -> Result<Vec<Vec<f32>>, RigError> {
    embed_impl(RigConfig::from_env()?, texts).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn embed_configured(
    config_json: String,
    texts: Vec<String>,
) -> Result<Vec<Vec<f32>>, RigError> {
    embed_impl(RigConfig::from_json(&config_json)?, texts).await
}

async fn embed_impl(config: RigConfig, texts: Vec<String>) -> Result<Vec<Vec<f32>>, RigError> {
    if texts.is_empty() {
        return Ok(Vec::new());
    }
    if config.embed_api_key.is_empty() {
        return Err(config_error("OPENROUTER_API_KEY is not set"));
    }
    let model_id = config.embed_model.clone();
    let input_json = json!({"texts": texts.as_slice()}).to_string();
    let span = tracing::info_span!(
        "embeddings",
        gen_ai.operation.name = "embeddings",
        gen_ai.provider.name = "openrouter",
        gen_ai.request.model = %model_id,
        gen_ai.response.model = tracing::field::Empty,
        openinference.span.kind = "EMBEDDING",
        llm.provider = "openrouter",
        llm.model_name = %model_id,
        input.value = %input_json,
        input.mime_type = "application/json",
        output.value = tracing::field::Empty,
        output.mime_type = "application/json",
    );
    let embedder = OpenAIConfig::new(config.embed_api_key.clone())
        .with_base_url(config.embed_base_url.clone())
        .client()
        .embedding(model_id, None);
    let timeout = timeout_seconds(config.timeout_s, 120.0);
    let response = tokio::time::timeout(
        Duration::from_secs_f64(timeout),
        embedder.call(texts).instrument(span.clone()),
    )
    .await
    .map_err(|_| RigError::Llm {
        message: format!("timed out after {timeout}s"),
    })?
    .map_err(llm_error)?;
    let vectors: Vec<Vec<f32>> = response
        .embeddings
        .into_iter()
        .map(|embedding| embedding.vec.into_iter().map(|v| v as f32).collect())
        .collect();
    let output_json = json!({
        "count": vectors.len(),
        "dimensions": vectors.first().map(|v| v.len()).unwrap_or(0),
    })
    .to_string();
    span.record("output.value", output_json.as_str());
    Ok(vectors)
}

/// One typed Jev `Noul` (yes/no) judgment through Command Code's System One route.
#[uniffi::export(async_runtime = "tokio")]
pub async fn jev_noul(question: String, state: String) -> Result<JevDecision, RigError> {
    let config = RigConfig::from_env()?;
    let model = config.jev_model.clone();
    let state_value = serde_json::from_str::<Value>(&state)
        .unwrap_or_else(|_| Value::String(state.clone()));
    let input_json = json!({"question": question, "state": state_value}).to_string();
    let span = tracing::info_span!(
        "jev",
        gen_ai.operation.name = "jev",
        gen_ai.provider.name = "typesafe",
        gen_ai.request.model = %model,
        gen_ai.response.model = tracing::field::Empty,
        gen_ai.usage.input_tokens = tracing::field::Empty,
        gen_ai.usage.output_tokens = tracing::field::Empty,
        openinference.span.kind = "LLM",
        llm.model_name = %model,
        llm.provider = "typesafe",
        llm.system = "typesafe",
        input.value = %input_json,
        input.mime_type = "application/json",
        output.value = tracing::field::Empty,
        output.mime_type = "application/json",
    );
    let result = async {
        let client = jev_client(&config)?;
        let query = Noul::new(question)
            .and_then(|q| q.named("decision"))
            .map_err(jev_error)?;
        client
            .evaluation()
            .evaluate(&state, query)
            .await
            .map_err(jev_error)
    }
    .instrument(span.clone())
    .await?;
    span.record("gen_ai.response.model", result.model.as_str());
    if let Some(Usage { input_tokens: Some(n), .. }) = result.usage {
        span.record("gen_ai.usage.input_tokens", n);
    }
    if let Some(Usage { output_tokens: Some(n), .. }) = result.usage {
        span.record("gen_ai.usage.output_tokens", n);
    }
    let output_json = json!({
        "probability": result.answers.noul,
        "model": result.model,
    })
    .to_string();
    span.record("output.value", output_json.as_str());
    Ok(JevDecision {
        question_id: "decision".into(),
        probability: result.answers.noul,
        model: result.model,
    })
}

/// Runtime-defined Jev questions: supports `Noul`, `Choice`, and `Score`, with
/// the same named dynamic question IDs as the Swift `JevClient` did.
#[uniffi::export(async_runtime = "tokio")]
pub async fn jev_dynamic(
    state_json: String,
    questions_json: String,
) -> Result<JevDynamicResult, RigError> {
    jev_dynamic_impl(RigConfig::from_env()?, state_json, questions_json).await
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn jev_dynamic_configured(
    config_json: String,
    state_json: String,
    questions_json: String,
) -> Result<JevDynamicResult, RigError> {
    jev_dynamic_impl(
        RigConfig::from_json(&config_json)?,
        state_json,
        questions_json,
    )
    .await
}

async fn jev_dynamic_impl(
    config: RigConfig,
    state_json: String,
    questions_json: String,
) -> Result<JevDynamicResult, RigError> {
    if !config.jev_enabled {
        return Err(RigError::Jev {
            message: "Jev is disabled".into(),
        });
    }
    let model = config.jev_model.clone();
    let state_value: Value = serde_json::from_str(&state_json)
        .map_err(|e| config_error(format!("state JSON: {e}")))?;
    let questions_value: Value = serde_json::from_str(&questions_json)
        .map_err(|e| config_error(format!("questions JSON: {e}")))?;
    let input_json = json!({
        "state": state_value,
        "questions": questions_value,
    })
    .to_string();
    let span = tracing::info_span!(
        "jev",
        gen_ai.operation.name = "jev",
        gen_ai.provider.name = "typesafe",
        gen_ai.request.model = %model,
        gen_ai.response.model = tracing::field::Empty,
        gen_ai.usage.input_tokens = tracing::field::Empty,
        gen_ai.usage.output_tokens = tracing::field::Empty,
        openinference.span.kind = "LLM",
        llm.model_name = %model,
        llm.provider = "typesafe",
        llm.system = "typesafe",
        input.value = %input_json,
        input.mime_type = "application/json",
        output.value = tracing::field::Empty,
        output.mime_type = "application/json",
    );
    let timeout = timeout_seconds(config.jev_timeout_s, 120.0);
    let result = tokio::time::timeout(Duration::from_secs_f64(timeout), async {
        let client = jev_client(&config)?;
        let definitions: BTreeMap<String, Question> =
            serde_json::from_value(questions_value.clone())
                .map_err(|e| config_error(format!("questions JSON: {e}")))?;
        let query = DynamicQuery::new(definitions).map_err(jev_error)?;
        client
            .evaluation()
            .evaluate(&state_value, query)
            .await
            .map_err(jev_error)
    }
    .instrument(span.clone()))
    .await
    .map_err(|_| RigError::Jev {
        message: format!("timed out after {timeout}s"),
    })??;
    span.record("gen_ai.response.model", result.model.as_str());
    if let Some(Usage { input_tokens: Some(n), .. }) = result.usage {
        span.record("gen_ai.usage.input_tokens", n);
    }
    if let Some(Usage { output_tokens: Some(n), .. }) = result.usage {
        span.record("gen_ai.usage.output_tokens", n);
    }
    let output_json = json!({
        "answers": result.answers,
        "model": result.model,
    })
    .to_string();
    span.record("output.value", output_json.as_str());
    let usage = result.usage;
    Ok(JevDynamicResult {
        answers_json: serde_json::to_string(&result.answers).map_err(jev_error)?,
        model: result.model,
        input_tokens: usage.and_then(|usage| usage.input_tokens),
        output_tokens: usage.and_then(|usage| usage.output_tokens),
        request_id: result.provider_request_id,
    })
}

fn jev_endpoint(base_url: &str) -> String {
    let trimmed = base_url.trim_end_matches('/');
    if trimmed.ends_with("/systemone") {
        trimmed.to_string()
    } else {
        format!("{trimmed}/v1/systemone")
    }
}

fn jev_client(config: &RigConfig) -> Result<rig::typesafeai::Jev, RigError> {
    let token = config
        .jev_api_key
        .clone()
        .filter(|token| !token.is_empty())
        .unwrap_or_else(|| config.api_key.clone());
    if token.is_empty() {
        return Err(config_error("neither JEV_TOKEN nor CMD_API_KEY is set"));
    }
    Ok(JevConfig::new(token)
        .with_endpoint(jev_endpoint(&config.jev_base_url))
        .model(config.jev_model.clone())
        .client())
}
