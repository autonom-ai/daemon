module daemon.interop.devin.session.catalog;

import daemon.interop.devin.bridge : Bridge;
import daemon.interop.devin.catalog : heldLock;
import daemon.interop.devin.connection : observedDirectory;
import daemon.interop.devin.session : Session;
import daemon.interop.metadata : SessionMetadata;

bool online(Bridge owner, string id)
{
    Session.validateId(id);
    return heldLock(owner.lockPath(id));
}

SessionMetadata sessionMetadata(Bridge owner, string id)
{
    Session.validateId(id);
    SessionMetadata ret = owner.catalog.metadata(id);

    if (!ret.id.length)
        ret.directory = owner.observedDirectory(id);

    return ret;
}

string lockPath(const Bridge owner, string id)
    => owner.catalog.lockPath(id);
