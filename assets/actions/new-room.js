const rooms = await context.request({ action: "getRooms" });
const names = new Set((Array.isArray(rooms) ? rooms : []).map((room) => room?.name));
let index = names.size + 1;
while (names.has(`room-${index}`))
    index += 1;

await context.request({ action: "createRoom", name: `room-${index}` });
await context.refresh();
