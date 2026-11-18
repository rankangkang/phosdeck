import ExtensionFoundation
import PhosdeckPluginKit

@main
struct SoftProofExtension: AppExtension {
    @AppExtensionPoint.Bind
    var extensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(host: "dev.cmkk.oh-my-lrc", name: "PhotoTool")
    }

    var configuration: ConnectionHandler { photoToolConfiguration(PrintProof()) }
}
