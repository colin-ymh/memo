#!/usr/bin/env node

async function main() {
    const chunks = [];
    for await (const chunk of process.stdin) {
        chunks.push(chunk);
    }

    const input = JSON.parse(Buffer.concat(chunks).toString());
    const toolName = input.tool_name || "";
    const toolInput = input.tool_input || {};

    const candidatePaths = [
        toolInput.file_path,
        toolInput.path,
        toolInput.pattern,
        toolInput.query,
    ]
        .filter(Boolean)
        .map(String);

    const blockedPatterns = [
        ".env",
        ".env.local",
        ".env.development",
        ".env.production",
        "secrets/",
    ];

    const isBlocked = candidatePaths.some((value) =>
        blockedPatterns.some((pattern) => value.includes(pattern))
    );

    if (isBlocked) {
        console.error(
            `[hook] Blocked ${toolName}: sensitive files or secrets paths cannot be read or searched.`
        );
        process.exit(2);
    }

    process.exit(0);
}

main().catch((err) => {
    console.error(`[hook] Error in block-sensitive-read: ${err.message}`);
    process.exit(1);
});
