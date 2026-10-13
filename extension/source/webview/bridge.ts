declare function acquireVsCodeApi(): {
    postMessage(message: unknown): void;
    getState(): unknown;
    setState(state: unknown): void;
};

interface PendingRequest {
    resolve: (value: any) => void;
    reject: (error: Error) => void;
    timer: ReturnType<typeof setTimeout>;
}

export class WebviewBridge {
    private vscode: { postMessage(message: unknown): void; getState(): unknown; setState(state: unknown): void } | null = null;
    private sequence = 0;
    private pending = new Map<string, PendingRequest>();
    private listeners = new Set<(message: any) => void>();

    constructor() {
        if (typeof acquireVsCodeApi === "function") {
            try {
                this.vscode = acquireVsCodeApi();
            } catch {
                // Already acquired or unavailable
            }
        }
        if (typeof window !== "undefined") {
            window.addEventListener("message", (event) => {
                const data = event.data;
                if (!data || typeof data !== "object") return;

                const correlationId = data.reqId || data.id;
                if (correlationId && this.pending.has(correlationId)) {
                    const req = this.pending.get(correlationId)!;
                    this.pending.delete(correlationId);
                    clearTimeout(req.timer);
                    if (data.error) {
                        req.reject(new Error(data.error));
                    } else {
                        req.resolve(data.result);
                    }
                    return;
                }

                for (const listener of this.listeners) {
                    try {
                        listener(data);
                    } catch {}
                }
            });
        }
    }

    async request<T = any>(action: string, parameters: Record<string, unknown> = {}): Promise<T> {
        if (!this.vscode) {
            throw new Error("VS Code webview API is not available.");
        }
        const reqId = `req_${++this.sequence}_${Date.now()}`;
        return new Promise<T>((resolve, reject) => {
            const timer = setTimeout(() => {
                this.pending.delete(reqId);
                reject(new Error(`Timed out waiting for action: ${action}`));
            }, 20000);
            this.pending.set(reqId, { resolve, reject, timer });
            this.vscode!.postMessage({ action, params: parameters, ...parameters, reqId });
        });
    }

    onMessage(listener: (message: any) => void): () => void {
        this.listeners.add(listener);
        return () => this.listeners.delete(listener);
    }
}

export const bridge = new WebviewBridge();
