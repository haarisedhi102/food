uniffi::setup_scaffolding!();

use std::collections::{BTreeMap, HashMap};
use std::sync::OnceLock;

use opentelemetry::trace::TracerProvider as _;
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

fn chat_client() -> Result<OpenAI, RigError> {
    let api_key = std::env::var("CMD_API_KEY")
        .map_err(|_| config_error("CMD_API_KEY is not set"))?;
    let base_url = std::env::var("RIG_POC_BASE_URL")
        .unwrap_or_else(|_| "https://api.commandcode.ai/provider/v1".into());
    Ok(OpenAIConfig::new(api_key)
        .with_base_url(base_url)
        .client())
}

fn chat_model_id() -> String {
    std::env::var("RIG_POC_MODEL")
        .unwrap_or_else(|_| "xiaomi/mimo-v2.6-flash".into())
}

fn max_tokens() -> u64 {
    std::env::var("RIG_POC_MAX_TOKENS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(8192)
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
    let exporter = SpanExporter::builder()
        .with_http()
        .with_endpoint(endpoint)
        .build()
        .map_err(|error| error.to_string())?;
    Ok(SdkTracerProvider::builder()
        // Export on span end. This avoids needing a Tokio reactor on the batch thread and
        // guarantees a short-lived process flushes before exit.
        .with_simple_exporter(exporter)
        .with_resource(Resource::builder().with_service_name(service_name.to_string()).build())
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
    let client = chat_client()?;
    let model_id = chat_model_id();
    let input_json = json!({"prompt": prompt}).to_string();
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
    let response = client
        .completion(model_id)
        .call(
            CompletionRequest::new(prompt)
                .temperature(Some(0.2))
                .max_tokens(Some(max_tokens()))
                .record_content_telemetry(true),
        )
        .instrument(span.clone())
        .await
        .map_err(llm_error)?;
    let text = response.text();
    span.record("output.value", text.as_str());
    Ok(ChatText {
        text,
        model: response.model().unwrap_or("unknown").to_string(),
    })
}

/// System/user completion returning raw text, the equivalent of `chatJSON`.
#[uniffi::export(async_runtime = "tokio")]
pub async fn chat_json(
    system: String,
    user: String,
    temperature: f64,
) -> Result<ChatText, RigError> {
    let client = chat_client()?;
    let model_id = chat_model_id();
    let input_json = json!({
        "system": system,
        "user": user,
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
    let response = client
        .completion(model_id)
        .call(
            CompletionRequest::new(user)
                .preamble(system)
                .temperature(Some(temperature))
                .max_tokens(Some(max_tokens()))
                .record_content_telemetry(true),
        )
        .instrument(span.clone())
        .await
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
    let client = chat_client()?;
    let model_id = chat_model_id();
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
        .max_tokens(Some(max_tokens()))
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
    let response = client
        .completion(model_id)
        .call(request)
        .instrument(span.clone())
        .await
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
    if texts.is_empty() {
        return Ok(Vec::new());
    }
    let api_key = std::env::var("OPENROUTER_API_KEY")
        .map_err(|_| config_error("OPENROUTER_API_KEY is not set"))?;
    let base_url = std::env::var("RIG_POC_EMBED_BASE_URL")
        .unwrap_or_else(|_| "https://openrouter.ai/api/v1".into());
    let model_id = std::env::var("RIG_POC_EMBED_MODEL")
        .unwrap_or_else(|_| "baai/bge-base-en-v1.5".into());
    let input_json = json!({"texts": texts}).to_string();
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
    let embedder = OpenAIConfig::new(api_key)
        .with_base_url(base_url)
        .client()
        .embedding(model_id, None);
    let response = embedder
        .call(texts)
        .instrument(span.clone())
        .await
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
    let model = std::env::var("RIG_POC_JEV_MODEL")
        .unwrap_or_else(|_| "typesafe/jev-1.14.0".into());
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
        let client = jev_client()?;
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
/// the same named dynamic question IDs as `JevClient`.
#[uniffi::export(async_runtime = "tokio")]
pub async fn jev_dynamic(
    state_json: String,
    questions_json: String,
) -> Result<JevDynamicResult, RigError> {
    let model = std::env::var("RIG_POC_JEV_MODEL")
        .unwrap_or_else(|_| "typesafe/jev-1.14.0".into());
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
    let result = async {
        let client = jev_client()?;
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
        "answers": result.answers,
        "model": result.model,
    })
    .to_string();
    span.record("output.value", output_json.as_str());
    Ok(JevDynamicResult {
        answers_json: serde_json::to_string(&result.answers).map_err(jev_error)?,
        model: result.model,
    })
}

fn jev_client() -> Result<rig::typesafeai::Jev, RigError> {
    let token = std::env::var("JEV_TOKEN")
        .or_else(|_| std::env::var("CMD_API_KEY"))
        .map_err(|_| config_error("neither JEV_TOKEN nor CMD_API_KEY is set"))?;
    let endpoint = std::env::var("RIG_POC_JEV_ENDPOINT")
        .unwrap_or_else(|_| "https://api.commandcode.ai/provider/v1/systemone".into());
    let model = std::env::var("RIG_POC_JEV_MODEL")
        .unwrap_or_else(|_| "typesafe/jev-1.14.0".into());
    Ok(JevConfig::new(token)
        .with_endpoint(endpoint)
        .model(model)
        .client())
}
