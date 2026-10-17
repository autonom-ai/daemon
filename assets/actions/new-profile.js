const profiles = await context.request({ action: "getProfiles" });
const names = new Set((Array.isArray(profiles) ? profiles : []).map((profile) => profile?.name));
let index = names.size + 1;
while (names.has(`profile-${index}`))
    index += 1;

await context.request({ action: "createProfile", name: `profile-${index}` });
await context.refresh();
