import { AutonomApp } from "./app";

function bootstrap(): void {
    const mount = document.getElementById("app");
    if (!mount) {
        console.error("[Autonom] Mount element #app not found");
        return;
    }
    const app = new AutonomApp(mount);
    app.init().catch((err: unknown) => {
        console.error("[Autonom] Failed to initialize app:", err);
    });
}

if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", bootstrap);
} else {
    bootstrap();
}
