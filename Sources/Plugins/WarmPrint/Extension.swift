import ExtensionFoundation
import PhosdeckPluginKit

@main
struct WarmPrintExtension: AppExtension {
    @AppExtensionPoint.Bind
    var extensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(host: "dev.cmkk.oh-my-lrc", name: "PhotoTool")
    }

    var configuration: ConnectionHandler { photoToolConfiguration(WarmPrint()) }
}
