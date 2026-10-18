/** Provider attribution is bounded to native React ownership, never nearby labels. */
export function createIconProviders(readIcons: () => Record<string, string>)
{
    const acpSessionProviders = new Map<string, string | null>();
    let recorded = new WeakSet<object>();
    function acpRegistryIcon(element: Element): string | undefined
    {
        const key = Object.keys(element).find((name) => name.startsWith("__reactFiber$"));
        const target = key ? (element as any)[key] : null;
        let fiber = target;
        for (let index = 0; fiber && index < 16; index++, fiber = fiber.return)
        {
            const props = fiber.memoizedProps;
            acpRecordSessions(props);
            const providerId = acpProviderId(props);
            if (providerId === undefined)
                continue;

            return acpIconSlot(element, target, fiber, props) ? readIcons()[providerId] : undefined;
        }
        return acpCodiconIcon(element);
    }

    function acpRecordSessions(props: any): void
    {
        if (!props || typeof props !== "object" || recorded.has(props))
            return;

        recorded.add(props);
        for (const value of Object.values(props))
        {
            if (Array.isArray(value))
                value.forEach(acpRecordSession);
            else
                acpRecordSession(value);
        }
    }

    function acpRecordSession(session: unknown): void
    {
        if (!session || typeof session !== "object")
            return;
        const { sessionId, providerId } = session as { sessionId?: unknown; providerId?: unknown };
        if (typeof sessionId !== "string" || typeof providerId !== "string")
            return;
        const slug = sessionId.split("/").pop();
        if (!slug)
            return;
        const known = acpSessionProviders.get(slug);
        if (known === undefined)
        {
            if (acpSessionProviders.size >= 4096)
                acpSessionProviders.delete(acpSessionProviders.keys().next().value!);
            acpSessionProviders.set(slug, providerId);
        }
        else if (known !== providerId)
            acpSessionProviders.set(slug, null);
    }

    function acpCodiconIcon(element: Element): string | undefined
    {
        if (!element.classList?.contains("codicon-devin-logo"))
            return undefined;
        const scope = element.closest(".monaco-icon-label") ?? element.closest(".quick-input-list-row");
        const description = scope?.querySelector(".monaco-icon-description-container")?.textContent?.trim();
        if (description && readIcons()[description])
            return readIcons()[description];
        const slug = element.closest("[data-resource-name]")?.getAttribute("data-resource-name");
        const providerId = slug ? acpSessionProviders.get(slug) : undefined;
        return providerId ? readIcons()[providerId] : undefined;
    }

    function acpProviderId(props: any): string | undefined
    {
        if (typeof props?.providerId === "string")
            return props.providerId;
        if (typeof props?.agent?.id === "string")
            return props.agent.id;
        if (typeof props?.agentId === "string")
            return props.agentId;
        if (typeof props?.session?.providerId === "string")
            return props.session.providerId;
        return undefined;
    }

    function acpIconSlot(element: Element, target: any, fiber: any, props: any): boolean
    {
        if (typeof props?.session?.providerId === "string" && acpProviderId(props) === props.session.providerId)
        {
            const child = fiber.child;
            if (!("isWaiting" in props && "size" in props) || !child || child.tag !== 5)
                return false;
            for (let probe = target, index = 0; probe && probe !== fiber && index < 128;
                probe = probe.return, index++)
            {
                if (probe === child)
                    return true;
            }
            return false;
        }

        const icon = props?.icon;
        if (icon && typeof icon === "object")
        {
            for (let probe = target, index = 0; probe && probe !== fiber && index < 128;
                probe = probe.return, index++)
            {
                if (probe.memoizedProps === icon.props)
                    return true;
            }
            return false;
        }
        return fiber.stateNode === element || acpFirstHost(fiber) === element;
    }

    function acpFirstHost(fiber: any): Element | null
    {
        let node = fiber.child;
        let remaining = 128;
        while (node && remaining-- > 0)
        {
            if (node.tag === 5 && node.stateNode)
                return node.stateNode;
            if (node.child)
            {
                node = node.child;
                continue;
            }
            while (node && node !== fiber && !node.sibling && remaining-- > 0)
                node = node.return;
            node = !node || node === fiber ? null : node.sibling;
        }
        return null;
    }

    return {
        icon: acpRegistryIcon,
        begin(): void
        {
            recorded = new WeakSet();
        },
    };
}
