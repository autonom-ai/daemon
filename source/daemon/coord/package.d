/// Multi-profile rooms, message streams, and cursor-tracked coordination bus.
module daemon.coord;

public import daemon.coord.bus : Bus;
public import daemon.coord.room : Room;
public import daemon.coord.stream : Entry, Stream;
