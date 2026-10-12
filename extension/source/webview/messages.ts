import { avatar, contentText, escape, icon, timeLabel } from "./dom";
import { record, text } from "../protocol";
import type { ConversationMessage, Entry } from "../protocol";

import MarkdownIt from "markdown-it";

const markdown = new MarkdownIt({ html: false, linkify: true, breaks: true });
markdown.renderer.rules.image = (tokens, index) => `[${escape(tokens[index]?.content || "Image")}]`;

export function renderMarkdown(content: string): string
{
    return markdown.render(content.slice(0, 262144));
}

export function renderEntries(entries: Entry[]): string
{
    if (!entries.length)
        return emptyConversation("No messages yet", "Start a conversation. Mention a profile to send a ping.");
    return entries.map((entry, index) =>
    {
        const merged = entries[index - 1]?.from === entry.from;
        return `<article class="message ${entry.from === "human" ? "human" : ""} ${merged ? "merged" : ""}">
            ${merged ? "<span class=avatar-placeholder></span>" : avatar(entry.from)}
            <div class="message-body">${merged ? "" : `<div class="message-meta"><strong>${escape(entry.from)}</strong><time>${escape(timeLabel(entry.ts))}</time>${entry.room ? `<span class="message-label">#${escape(entry.room)}</span>` : ""}</div>`}
            <div class="markdown">${renderMarkdown(entry.text)}</div></div></article>`;
    }).join("");
}

export function renderConversation(messages: ConversationMessage[]): string
{
    const ret: string[] = [];
    for (const [index, message] of messages.entries())
    {
        const role = text(message.role);
        if (role === "system")
            continue;
        const content = contentText(message.content);
        const user = role === "user";
        const tools = Array.isArray(message.tool_calls) ? message.tool_calls : [];
        const thought = contentText(message.reasoning_content);
        const observation = record(message.observation);
        const results = Array.isArray(observation?.results) ? observation.results : [];
        if (role === "tool")
        {
            ret.push(`<details class="tool-card" data-key="result-${index}"><summary>${icon("terminal")}<span>${escape(text(message.name, "Tool result"))}</span>${icon("chevron-right", "disclosure")}</summary><pre>${escape(content.slice(0, 65536))}</pre></details>`);
            continue;
        }
        if (content)
            ret.push(`<article class="message ${user ? "human request" : "agent-response"}">
                ${avatar(user ? "you" : "AI")}
                <div class="message-body"><div class="message-meta"><strong>${user ? "You" : "Agent"}</strong><time>${escape(timeLabel(message.timestamp))}</time></div><div class="markdown">${renderMarkdown(content)}</div></div></article>`);
        if (thought)
            ret.push(`<details class="thought-card" data-key="thought-${index}"><summary>${icon("lightning-charge")}<span>Reasoning</span>${icon("chevron-right", "disclosure")}</summary><div class="markdown">${renderMarkdown(thought)}</div></details>`);
        for (const [toolIndex, value] of tools.entries())
        {
            const tool = record(value);
            if (tool === undefined)
                continue;
            const fn = record(tool.function);
            const title = text(tool.function_name, text(fn?.name, text(tool.name, "Tool call")));
            const argumentsValue: unknown = tool.arguments ?? fn?.arguments ?? {};
            const argumentsRecord = record(argumentsValue);
            const detail = text(argumentsRecord?.command, text(argumentsRecord?.file_path, text(argumentsRecord?.tool_name)));
            const toolId = text(tool.tool_call_id, text(tool.id));
            const result = results.map(record).find((result) => text(result?.source_call_id) === toolId);
            const symbol = title.includes("exec") ? "terminal" : title.includes("read") ? "file-earmark-text"
                : title.includes("mcp") ? "diagram-3-fill" : "code-slash";
            ret.push(`<details class="tool-card" data-key="tool-${index}-${toolIndex}"><summary>${icon(symbol)}<span>${escape(title.replaceAll("mcp__autonom-coord__", ""))}</span>${detail ? `<code>${escape(detail.slice(0, 140))}</code>` : ""}${icon("chevron-right", "disclosure")}</summary>
                <div class="tool-section"><span class="eyebrow">Input</span><pre>${escape(typeof argumentsValue === "string" ? argumentsValue : JSON.stringify(argumentsValue, null, 2))}</pre></div>
                ${result ? `<div class="tool-section"><span class="eyebrow">Result</span><pre>${escape(contentText(result.content).slice(0, 65536))}</pre></div>` : ""}</details>`);
        }
    }
    return ret.length ? ret.join("") : emptyConversation("Session is starting", "Your agent is getting ready. Its activity will appear here.");
}

export function emptyConversation(title: string, detail: string): string
{
    return `<div class="empty-conversation">${icon("chat-square-text")}<h2>${escape(title)}</h2><p>${escape(detail)}</p></div>`;
}
