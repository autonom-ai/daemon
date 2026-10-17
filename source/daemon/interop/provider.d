module daemon.interop.provider;

import daemon.interop.access : Access;
import daemon.interop.call : Call;
import daemon.interop.metadata : SessionMetadata;
import daemon.interop.session : Session;

/// Worker-owned session provider. Launch methods return immediately with an owned call.
interface IProvider
{
    Access access();

    Session session(string id);

    Session findSession(string id);

    Session[] list(string directory = null, string acp = null);

    SessionMetadata sessionMetadata(string id);

    bool online(string id);

    bool isRemoved(string id);

    Call start(string prompt, string directory, string model = null, string mode = null,
        bool trusted = false, string profileName = null);

    Call resume(string id, string prompt, string directory, string model,
        bool compactFirst = false, string mode = null);

    Call execution(string id);

    Call[] listCalls(string directory = null);

    Call authenticate(string token, string id, bool bind = false);

    string[] collect();

    void stopSessions();

    void close();
}
