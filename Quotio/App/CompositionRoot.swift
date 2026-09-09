import AppKit
import Foundation
import QuotioApplication
import QuotioDomain
import QuotioInfrastructure
import QuotioPresentation

enum AppEnvironment {
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

@MainActor
enum CompositionRoot {
    static func makeProduction() -> AppRuntime {
        if !AppEnvironment.isRunningUnitTests {
            AppIdentity.migrateLegacyUserDefaults()
        }

        let customProviderRepository = UserDefaultsCustomProviderRepository()
        let customProviderTransport = URLSessionCustomProviderTransport()
        let customProviderService = QuotioApplication.CustomProviderService(
            repository: customProviderRepository,
            discovery: customProviderTransport,
            connectionTester: customProviderTransport,
            configurationSynchronizer: FileCustomProviderConfigurationSynchronizer()
        )
        let urlOpener = WorkspaceURLOpener()
        let applicationPlatform = AppKitApplicationPlatformAdapter()
        let pasteboard = PasteboardScreenModel(writer: MacOSPasteboardAdapter())
        let yubiKeyVault = YubiKeyVaultAdapter()
        let languageManager = LanguageManager(
            repository: UserDefaultsLanguagePreferencesRepository()
        )
        let proxyPreferences = UserDefaultsProxyPreferencesRepository()
        let managementAPIFactory = LiveProxyManagementAPIFactory()
        let notificationController = NotificationController(
            repository: UserDefaultsNotificationPreferencesRepository(),
            delivery: UserNotificationCenterAdapter { [languageManager] key in
                languageManager.localized(key)
            }
        )
        let paths = FileProxyConfigurationRepository.defaultPaths()
        let configurationRepository = FileProxyConfigurationRepository(paths: paths)
        let proxyController = ProxyLifecycleController(
            paths: paths,
            processController: ProxyProcessController(),
            versionRepository: FileProxyVersionRepository(),
            releaseRepository: GitHubProxyReleaseRepository(),
            updateFeed: GitHubAtomProxyUpdateFeed(),
            configurationRepository: configurationRepository,
            binaryDownloader: URLSessionProxyBinaryDownloader(),
            checksumVerifier: SHA256ProxyChecksumVerifier(),
            managementChecker: LocalProxyManagementClient(),
            metadataRepository: UserDefaultsProxyRuntimeMetadataRepository(),
            preferencesRepository: UserDefaultsProxyPreferencesRepository(),
            keyVault: ProxyManagementKeyVaultAdapter(
                dataStore: KeychainCredentialDataStore(
                    service: AppIdentity.keychainService(suffix: "local-management"),
                    legacyServices: AppIdentity.legacyKeychainServices(suffix: "local-management"),
                    canMigrateLegacy: AppIdentity.isProduction,
                    protectedStore: yubiKeyVault
                )
            ),
            configurationSupplement: CustomProviderConfigurationSupplement(
                service: customProviderService
            ),
            notificationDelivery: ProxyNotificationRelay(notifications: notificationController),
            sleeper: ContinuousSleeper(),
            dateProvider: SystemDateProvider(),
            installedVersionLimit: AppConstants.maxInstalledVersions
        )
        let proxyScreenModel = ProxyScreenModel(
            controller: proxyController,
            initialState: ProxySnapshot(
                status: ProxyStatus(
                    port: UserDefaultsProxyRuntimeMetadataRepository().loadPort()
                ),
                paths: paths
            )
        )

        let authFileRepository = FileAuthFileRepository()
        let metadataRepository = FileAccountMetadataRepository()
        let externalCredentials = ExternalKeychainCredentialReader()
        let quotaHTTPSession = ReloadableQuotaHTTPSession {
            URLSession(configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15))
        }
        let kiroHTTPSession = ReloadableQuotaHTTPSession {
            URLSession(configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 20))
        }
        let ampHTTPSession = ReloadableQuotaHTTPSession {
            AmpQuotaFetcher.makeSession()
        }
        let credentialVault = CredentialVaultService(
            dataStore: KeychainCredentialDataStore(
                service: AppIdentity.keychainService(suffix: "monitor-auth"),
                legacyServices: AppIdentity.legacyKeychainServices(suffix: "monitor-auth"),
                canMigrateLegacy: AppIdentity.isProduction,
                protectedStore: yubiKeyVault
            ),
            metadataRepository: metadataRepository
        )
        let accountDiscovery = LocalAccountDiscovery(
            vault: credentialVault,
            authFileRepository: authFileRepository,
            metadataRepository: metadataRepository,
            externalCredentials: externalCredentials
        )
        let accountService = AccountService(
            discovery: accountDiscovery,
            metadataRepository: metadataRepository,
            credentialVault: credentialVault,
            reservedLabels: [
                AccountProviderID(rawValue: QuotaProvider.amp.rawValue): [ProviderAccountKey.ampNative],
            ]
        )
        let accountsScreenModel = AccountsScreenModel(
            accountService: accountService,
            authFileRepository: authFileRepository
        )
        let kiroQuotaFetcher = QuotioInfrastructure.KiroQuotaFetcher(
            vault: credentialVault,
            metadata: metadataRepository,
            session: kiroHTTPSession
        )

        let monitorAuthorizer = MonitorOAuthAuthorizer(
            vault: credentialVault,
            urlOpener: urlOpener,
            callbackTransport: LoopbackOAuthCallbackTransport(),
            httpTransport: URLSessionOAuthHTTPTransport()
        ) { accessToken, expiresAt, clientID, clientSecret, region in
            await kiroQuotaFetcher.authenticatedAccountIdentity(
                accessToken: accessToken,
                expiresAt: expiresAt,
                clientID: clientID,
                clientSecret: clientSecret,
                region: region
            )
        }
        let localProxyAuthorizer = LocalProxyOAuthAuthorizer(
            runtime: { [proxyScreenModel] in
                LocalProxyOAuthRuntime(
                    cli: proxyScreenModel.isBinaryInstalled
                        ? ProxyCLIAuthRuntime(
                            binaryPath: proxyScreenModel.effectiveBinaryPath,
                            configurationPath: proxyScreenModel.configPath
                        )
                        : nil,
                    management: proxyScreenModel.proxyStatus.running
                        ? ProxyManagementConnection(
                            baseURL: proxyScreenModel.managementURL,
                            authKey: proxyScreenModel.managementKey
                        )
                        : nil
                )
            },
            authenticator: ProcessProxyCLIAuthenticator(copyDeviceCode: pasteboard.copy),
            authFiles: authFileRepository,
            urlOpener: urlOpener,
            managementAPIFactory: managementAPIFactory
        ) {
            await kiroQuotaFetcher.refreshAllLocalTokensIfNeeded()
        }
        let modeManager = OperatingModeManager(
            repository: UserDefaultsOperatingModePreferencesRepository()
        )
        let authorizer = OperatingModeOAuthAuthorizer(
            monitor: monitorAuthorizer,
            localProxy: localProxyAuthorizer
        ) {
            await MainActor.run { modeManager.isMonitorMode }
        }
        let oauthScreenModel = OAuthScreenModel(
            controller: OAuthFlowController(authorizer: authorizer)
        )

        let factoryDroidCredentials = LocalFactoryDroidCredentialStore()
        let warpTokenRepository = SecureWarpTokenRepository(
            dataStore: KeychainCredentialDataStore(
                service: AppIdentity.keychainService(suffix: "warp"),
                legacyServices: AppIdentity.legacyKeychainServices(suffix: "warp"),
                canMigrateLegacy: AppIdentity.isProduction,
                protectedStore: yubiKeyVault
            )
        )
        let warpTokenScreenModel = WarpTokenScreenModel(repository: warpTokenRepository)
        let registry = QuotaProviderRegistry([
            QuotioInfrastructure.ClaudeQuotaFetcher(
                credentials: CompositeClaudeQuotaCredentialLoader(
                    vault: credentialVault,
                    metadata: metadataRepository
                ),
                session: quotaHTTPSession
            ),
            QuotioInfrastructure.CodexQuotaFetcher(
                credentials: CompositeCodexQuotaCredentialLoader(
                    vault: credentialVault,
                    metadata: metadataRepository
                ),
                session: quotaHTTPSession
            ),
            QuotioInfrastructure.AntigravityQuotaFetcher(
                vault: credentialVault,
                metadata: metadataRepository,
                nativeCredentials: NativeAntigravityCredentialReader(session: quotaHTTPSession),
                session: quotaHTTPSession
            ),
            QuotioInfrastructure.CopilotQuotaFetcher(
                vault: credentialVault,
                metadata: metadataRepository,
                session: quotaHTTPSession
            ),
            kiroQuotaFetcher,
            QuotioInfrastructure.CursorQuotaFetcher(session: quotaHTTPSession),
            QuotioInfrastructure.TraeQuotaFetcher(session: quotaHTTPSession),
            QuotioInfrastructure.FactoryDroidQuotaFetcher(
                vault: credentialVault,
                metadata: metadataRepository,
                localCredentials: factoryDroidCredentials,
                credentialWriter: factoryDroidCredentials,
                session: quotaHTTPSession
            ),
            QuotioInfrastructure.GLMQuotaFetcher(
                repository: customProviderRepository,
                session: quotaHTTPSession
            ),
            QuotioInfrastructure.ClinePassQuotaFetcher(
                repository: customProviderRepository,
                session: quotaHTTPSession
            ),
            QuotioInfrastructure.WarpQuotaFetcher(
                repository: warpTokenRepository,
                session: quotaHTTPSession
            ),
            QuotioInfrastructure.OpenRouterQuotaFetcher(
                vault: credentialVault,
                metadata: metadataRepository,
                session: quotaHTTPSession
            ),
            QuotioInfrastructure.AmpQuotaFetcher(
                vault: credentialVault,
                metadata: metadataRepository,
                session: ampHTTPSession
            ),
            QuotioInfrastructure.DevinQuotaFetcher(session: quotaHTTPSession),
            QuotioInfrastructure.GrokQuotaFetcher(session: quotaHTTPSession),
        ])
        let quotaScreenModel = QuotaScreenModel(
            coordinator: QuotaRefreshCoordinator(
                registry: registry,
                snapshots: PersistentQuotaSnapshotStore(),
                clock: SystemDateProvider()
            )
        )
        let dashboardScreenModel = DashboardScreenModel(
            quota: quotaScreenModel,
            accounts: accountsScreenModel
        )
        let providersScreenModel = ProvidersScreenModel(
            accounts: accountsScreenModel,
            oauth: oauthScreenModel,
            quota: quotaScreenModel,
            customProviderService: customProviderService
        )
        providersScreenModel.reloadCustomProviders()

        let antigravityAccountScreenModel = AntigravityAccountScreenModel(
            switcher: AntigravityAccountSwitcherFactory.make(
                logger: OSApplicationLogger(
                    subsystem: AppIdentity.bundleIdentifier,
                    category: "Antigravity"
                )
            )
        )
        let refreshSettings = RefreshSettingsManager(
            repository: UserDefaultsRefreshPreferencesRepository()
        )
        let menuBarSettings = MenuBarSettingsManager(
            repository: UserDefaultsMenuBarPreferencesRepository()
        )
        let warmupSettings = WarmupSettingsManager(
            repository: UserDefaultsWarmupPreferencesRepository()
        )
        let ideScanSettings = IDEScanSettingsManager()
        let remoteQuotaSourceScreenModel = RemoteQuotaSourceScreenModel(
            coordinator: RemoteQuotaSourceCoordinator(
                repository: UserDefaultsRemoteQuotaSourceRepository(),
                credentials: KeychainRemoteQuotaSourceCredentialVault(
                    dataStore: KeychainCredentialDataStore(
                        service: AppIdentity.keychainService(suffix: "remote-quota-source"),
                        canMigrateLegacy: false,
                        protectedStore: yubiKeyVault
                    ),
                    legacyReader: RawKeychainStringReader(),
                    legacyService: AppIdentity.keychainService(suffix: "remote-management")
                ),
                fetcher: RemoteManagementQuotaFetcher(),
                snapshotStore: UserDefaultsRemoteQuotaPoolSnapshotStore(),
                clock: SystemDateProvider()
            ),
            refreshSettings: refreshSettings,
            modeManager: modeManager,
            menuBarSettings: menuBarSettings
        )
        let quotaController = QuotaFeatureController(
            quota: quotaScreenModel,
            accounts: accountsScreenModel,
            oauth: oauthScreenModel,
            antigravityAccounts: antigravityAccountScreenModel,
            modeManager: modeManager,
            refreshSettings: refreshSettings,
            menuBarSettings: menuBarSettings,
            notifications: notificationController,
            authFiles: { [] }
        )
        antigravityAccountScreenModel.setDidSwitchHandler { [weak quotaController] in
            await quotaController?.refresh(provider: .antigravity)
        }
        let tunnelPreferences = UserDefaultsTunnelPreferencesRepository()
        let tunnelController = TunnelLifecycleController(
            tunnel: CloudflaredService(),
            remoteAccess: ProxyTunnelRemoteAccessAdapter(proxy: proxyScreenModel),
            preferences: tunnelPreferences,
            sleeper: ContinuousSleeper(),
            clock: SystemDateProvider()
        )
        let tunnel = TunnelScreenModel(
            controller: tunnelController,
            failureMessage: { failure in
                switch failure {
                case .notInstalled:
                    "tunnel.error.notInstalled".localized()
                case .alreadyRunning:
                    "Tunnel is already running"
                case .startFailed(let reason):
                    "Failed to start tunnel: \(reason)"
                case .unexpectedExit:
                    "tunnel.error.unexpectedExit".localized()
                case .startTimeout:
                    "tunnel.error.startTimeout".localized()
                @unknown default:
                    "tunnel.error.unexpectedExit".localized()
                }
            }
        )
        let agentFileStore = AgentFileStore()
        let agentDetector = AgentDetectionAdapter()
        let agentInstallationProbe = AgentBinaryInstallationProbe()
        let copilotAvailableModelCatalog = CopilotAvailableModelCatalog()
        let agentConfigurationService = QuotioApplication.AgentConfigurationService(
            adapters: [
                ClaudeCodeAgentConfigurationAdapter(fileStore: agentFileStore),
                CodexAgentConfigurationAdapter(fileStore: agentFileStore),
                AmpAgentConfigurationAdapter(fileStore: agentFileStore),
                OpenCodeAgentConfigurationAdapter(fileStore: agentFileStore),
                FactoryDroidAgentConfigurationAdapter(fileStore: agentFileStore),
            ],
            detector: agentDetector,
            shellProfiles: ShellProfileAdapter(fileStore: agentFileStore),
            modelCatalog: AgentModelCatalogHTTPAdapter {
                await copilotAvailableModelCatalog.availableModelIDs()
            }
        )
        weak var proxyManagementReference: ProxyManagementScreenModel?
        let agentSetup = AgentSetupScreenModel(
            service: agentConfigurationService,
            endpointContext: { [weak proxyScreenModel, weak tunnel] in
                guard let proxyScreenModel else { return nil }
                return AgentEndpointContext(
                    baseURL: tunnel?.tunnelState.publicURL ?? proxyScreenModel.baseURL,
                    apiKey: proxyManagementReference?.apiKeys.first ?? proxyScreenModel.managementKey
                )
            }
        )
        let proxyManagement = ProxyManagementScreenModel(
            proxy: proxyScreenModel,
            accounts: accountsScreenModel,
            oauth: oauthScreenModel,
            tunnel: tunnel,
            agentSetup: agentSetup,
            authWorkaround: FileAntigravityAuthWorkaround(),
            notifications: notificationController,
            refreshSettings: refreshSettings,
            tunnelPreferences: tunnelPreferences,
            proxyPreferences: proxyPreferences,
            authFileState: UserDefaultsManagedAuthFileStateRepository(),
            managementAPIFactory: managementAPIFactory
        )
        proxyManagementReference = proxyManagement
        quotaController.setAuthFilesProvider { [weak proxyManagement] in
            proxyManagement?.authFiles ?? []
        }
        proxyManagement.setQuotaRefresh { [weak quotaController] force in
            await quotaController?.refreshAll(force: force)
        }
        oauthScreenModel.setSuccessHandler { [weak proxyManagement, weak quotaController] in
            if !modeManager.isMonitorMode {
                await proxyManagement?.refreshData(refreshQuota: false)
            }
            await quotaController?.refreshAll(force: true)
        }

        let warmupExecutor = ProxyWarmupExecutor { [weak proxyManagement] in
            proxyManagement?.managementAPI
        }
        let warmupScreenModel = WarmupScreenModel(
            scheduler: WarmupSchedulerService(
                executor: warmupExecutor,
                availability: warmupExecutor,
                clock: SystemDateProvider(),
                sleeper: ContinuousSleeper()
            ),
            settings: warmupSettings,
            authFiles: { [weak proxyManagement] in proxyManagement?.authFiles ?? [] }
        )
        let ideImportScreenModel = IDEImportScreenModel(
            quotaController: quotaController,
            settings: ideScanSettings,
            cliToolProbe: CLIToolInstallationProbe()
        )

        let logRepository = QuotioInfrastructure.ManagementAPIClient(
            connectionProvider: { [proxyScreenModel] in
                await MainActor.run {
                    QuotioInfrastructure.ManagementAPIClient.Connection(
                        baseURL: proxyScreenModel.managementURL,
                        authKey: proxyScreenModel.managementKey
                    )
                }
            }
        )
        let logsScreenModel = LogsScreenModel(
            loadLogs: LoadProxyLogsUseCase(
                repository: logRepository,
                timeProvider: SystemDateProvider()
            ),
            clearLogs: ClearProxyLogsUseCase(repository: logRepository),
            sleeper: ContinuousSleeper()
        )
        let updatePreferences = UserDefaultsUpdatePreferencesRepository()
        let applicationUpdateController = ApplicationUpdateController(
            checker: SparkleApplicationUpdateAdapter(),
            preferencesRepository: updatePreferences,
            icon: AppKitUpdaterIconAdapter()
        )
        let applicationUpdateModel = ApplicationUpdateScreenModel(
            controller: applicationUpdateController
        )
        let notificationSettingsModel = NotificationSettingsScreenModel(
            controller: notificationController
        )
        let telemetryController = TelemetryController(
            repository: UserDefaultsTelemetryPreferencesRepository(),
            tracker: PostHogTelemetryAdapter(),
            contextProvider: BundleTelemetryRuntimeContextProvider(),
            updatePreferencesRepository: updatePreferences
        )
        let telemetryConsentModel = TelemetryConsentScreenModel(controller: telemetryController)
        let yubiKeySettingsModel = YubiKeySettingsScreenModel(vault: yubiKeyVault)
        let launchAtLoginController = LaunchAtLoginController(
            registration: ServiceManagementLaunchAtLoginAdapter(),
            urlOpener: urlOpener
        )
        let launchAtLoginModel = LaunchAtLoginScreenModel(
            controller: launchAtLoginController,
            failureMessage: { failure in
                switch failure {
                case .registrationFailed(let reason):
                    "launchAtLogin.error.registrationFailed".localized() + ": \(reason)"
                case .unregistrationFailed(let reason):
                    "launchAtLogin.error.unregistrationFailed".localized() + ": \(reason)"
                @unknown default:
                    "launchAtLogin.error.registrationFailed".localized()
                }
            }
        )
        let platformActions = PlatformActionScreenModel(urlOpener: urlOpener)
        let appearanceManager = AppearanceManager(
            repository: UserDefaultsAppearancePreferencesRepository(),
            platform: applicationPlatform
        )
        let proxyUpdatePolling = ProxyUpdatePollingController(
            proxy: proxyController,
            notifications: notificationController,
            notificationRecord: UserDefaultsProxyUpdateNotificationRecord(),
            sleeper: ContinuousSleeper()
        )
        let settingsScreenModel = SettingsScreenModel(
            proxyRepository: proxyPreferences,
            tunnelRepository: tunnelPreferences,
            appShellRepository: UserDefaultsAppShellPreferencesRepository(),
            applyNetworkAccess: { [proxyScreenModel] enabled in
                proxyScreenModel.setNetworkAccess(enabled)
            },
            applyAutomaticUpdateChecks: { [applicationUpdateController] enabled in
                applicationUpdateController.automaticallyChecksForUpdates = enabled
            },
            applyDockVisibility: { [applicationPlatform] enabled in
                applicationPlatform.setDockVisibility(enabled)
            },
            reloadQuotaNetwork: {
                async let reloadQuota: Void = quotaHTTPSession.reload()
                async let reloadKiro: Void = kiroHTTPSession.reload()
                async let reloadAmp: Void = ampHTTPSession.reload()
                _ = await (reloadQuota, reloadKiro, reloadAmp)
            }
        )
        let providerImageCache = ProviderImageCacheAdapter()
        let providerImageModel = ProviderImageScreenModel(
            loadImage: { [providerImageCache] name, size in
                providerImageCache.image(named: name, size: size)
            }
        )
        let statusBarManager = StatusBarManager()
        let services = ProductionAppRuntimeServices(
            proxyManagement: proxyManagement,
            quotaController: quotaController,
            quotaScreenModel: quotaScreenModel,
            remoteQuotaSourceScreenModel: remoteQuotaSourceScreenModel,
            accountsScreenModel: accountsScreenModel,
            dashboardScreenModel: dashboardScreenModel,
            providersScreenModel: providersScreenModel,
            warpTokenScreenModel: warpTokenScreenModel,
            navigationScreenModel: NavigationScreenModel(),
            warmupScreenModel: warmupScreenModel,
            ideImportScreenModel: ideImportScreenModel,
            antigravityAccountScreenModel: antigravityAccountScreenModel,
            logsScreenModel: logsScreenModel,
            pasteboard: pasteboard,
            providerImageModel: providerImageModel,
            platformActions: platformActions,
            settingsScreenModel: settingsScreenModel,
            modeManager: modeManager,
            appearanceManager: appearanceManager,
            statusBarManager: statusBarManager,
            menuBarSettings: menuBarSettings,
            languageManager: languageManager,
            refreshSettings: refreshSettings,
            warmupSettings: warmupSettings,
            ideScanSettings: ideScanSettings,
            launchAtLoginModel: launchAtLoginModel,
            notificationSettingsModel: notificationSettingsModel,
            telemetryConsentModel: telemetryConsentModel,
            applicationUpdateModel: applicationUpdateModel,
            yubiKeySettingsModel: yubiKeySettingsModel,
            notificationController: notificationController,
            telemetryController: telemetryController,
            applicationUpdateController: applicationUpdateController,
            applicationPlatform: applicationPlatform,
            proxyUpdatePolling: proxyUpdatePolling,
            tunnel: tunnel,
            isCLIInstalled: agentInstallationProbe.isInstalled
        )
        return AppRuntime(services: services)
    }
}

private struct CustomProviderConfigurationSupplement: ProxyConfigurationSupplementing {
    private let service: QuotioApplication.CustomProviderService

    init(service: QuotioApplication.CustomProviderService) {
        self.service = service
    }

    func synchronize(configurationPath: String) async {
        try? service.synchronizeConfiguration(at: configurationPath)
    }
}

@MainActor
private final class ProductionAppRuntimeServices: AppRuntimeServices {
    let proxyManagement: ProxyManagementScreenModel
    let quotaController: QuotaFeatureController
    let quotaScreenModel: QuotaScreenModel
    let remoteQuotaSourceScreenModel: RemoteQuotaSourceScreenModel
    let accountsScreenModel: AccountsScreenModel
    let dashboardScreenModel: DashboardScreenModel
    let providersScreenModel: ProvidersScreenModel
    let warpTokenScreenModel: WarpTokenScreenModel
    let navigationScreenModel: NavigationScreenModel
    let warmupScreenModel: WarmupScreenModel
    let ideImportScreenModel: IDEImportScreenModel
    let antigravityAccountScreenModel: AntigravityAccountScreenModel
    let logsScreenModel: LogsScreenModel
    let pasteboard: PasteboardScreenModel
    let providerImageModel: ProviderImageScreenModel
    let platformActions: PlatformActionScreenModel
    let settingsScreenModel: SettingsScreenModel
    let modeManager: OperatingModeManager
    let appearanceManager: AppearanceManager
    let statusBarManager: StatusBarManager
    let menuBarSettings: MenuBarSettingsManager
    let languageManager: LanguageManager
    let refreshSettings: RefreshSettingsManager
    let warmupSettings: WarmupSettingsManager
    let ideScanSettings: IDEScanSettingsManager
    let launchAtLoginModel: LaunchAtLoginScreenModel
    let notificationSettingsModel: NotificationSettingsScreenModel
    let telemetryConsentModel: TelemetryConsentScreenModel
    let applicationUpdateModel: ApplicationUpdateScreenModel
    let yubiKeySettingsModel: YubiKeySettingsScreenModel

    private let notificationController: NotificationController
    private let telemetryController: TelemetryController
    private let applicationUpdateController: ApplicationUpdateController
    private let applicationPlatform: AppKitApplicationPlatformAdapter
    private let proxyUpdatePolling: ProxyUpdatePollingController
    private let tunnel: TunnelScreenModel
    private let isCLIInstalled: (CLIAgent) -> Bool

    var hasCompletedOnboarding: Bool { modeManager.hasCompletedOnboarding }
    var showInDock: Bool { settingsScreenModel.appShellPreferences.showInDock }
    var canCheckForUpdates: Bool { applicationUpdateModel.snapshot.canCheck }

    init(
        proxyManagement: ProxyManagementScreenModel,
        quotaController: QuotaFeatureController,
        quotaScreenModel: QuotaScreenModel,
        remoteQuotaSourceScreenModel: RemoteQuotaSourceScreenModel,
        accountsScreenModel: AccountsScreenModel,
        dashboardScreenModel: DashboardScreenModel,
        providersScreenModel: ProvidersScreenModel,
        warpTokenScreenModel: WarpTokenScreenModel,
        navigationScreenModel: NavigationScreenModel,
        warmupScreenModel: WarmupScreenModel,
        ideImportScreenModel: IDEImportScreenModel,
        antigravityAccountScreenModel: AntigravityAccountScreenModel,
        logsScreenModel: LogsScreenModel,
        pasteboard: PasteboardScreenModel,
        providerImageModel: ProviderImageScreenModel,
        platformActions: PlatformActionScreenModel,
        settingsScreenModel: SettingsScreenModel,
        modeManager: OperatingModeManager,
        appearanceManager: AppearanceManager,
        statusBarManager: StatusBarManager,
        menuBarSettings: MenuBarSettingsManager,
        languageManager: LanguageManager,
        refreshSettings: RefreshSettingsManager,
        warmupSettings: WarmupSettingsManager,
        ideScanSettings: IDEScanSettingsManager,
        launchAtLoginModel: LaunchAtLoginScreenModel,
        notificationSettingsModel: NotificationSettingsScreenModel,
        telemetryConsentModel: TelemetryConsentScreenModel,
        applicationUpdateModel: ApplicationUpdateScreenModel,
        yubiKeySettingsModel: YubiKeySettingsScreenModel,
        notificationController: NotificationController,
        telemetryController: TelemetryController,
        applicationUpdateController: ApplicationUpdateController,
        applicationPlatform: AppKitApplicationPlatformAdapter,
        proxyUpdatePolling: ProxyUpdatePollingController,
        tunnel: TunnelScreenModel,
        isCLIInstalled: @escaping (CLIAgent) -> Bool
    ) {
        self.proxyManagement = proxyManagement
        self.quotaController = quotaController
        self.quotaScreenModel = quotaScreenModel
        self.remoteQuotaSourceScreenModel = remoteQuotaSourceScreenModel
        self.accountsScreenModel = accountsScreenModel
        self.dashboardScreenModel = dashboardScreenModel
        self.providersScreenModel = providersScreenModel
        self.warpTokenScreenModel = warpTokenScreenModel
        self.navigationScreenModel = navigationScreenModel
        self.warmupScreenModel = warmupScreenModel
        self.ideImportScreenModel = ideImportScreenModel
        self.antigravityAccountScreenModel = antigravityAccountScreenModel
        self.logsScreenModel = logsScreenModel
        self.pasteboard = pasteboard
        self.providerImageModel = providerImageModel
        self.platformActions = platformActions
        self.settingsScreenModel = settingsScreenModel
        self.modeManager = modeManager
        self.appearanceManager = appearanceManager
        self.statusBarManager = statusBarManager
        self.menuBarSettings = menuBarSettings
        self.languageManager = languageManager
        self.refreshSettings = refreshSettings
        self.warmupSettings = warmupSettings
        self.ideScanSettings = ideScanSettings
        self.launchAtLoginModel = launchAtLoginModel
        self.notificationSettingsModel = notificationSettingsModel
        self.telemetryConsentModel = telemetryConsentModel
        self.applicationUpdateModel = applicationUpdateModel
        self.yubiKeySettingsModel = yubiKeySettingsModel
        self.notificationController = notificationController
        self.telemetryController = telemetryController
        self.applicationUpdateController = applicationUpdateController
        self.applicationPlatform = applicationPlatform
        self.proxyUpdatePolling = proxyUpdatePolling
        self.tunnel = tunnel
        self.isCLIInstalled = isCLIInstalled
    }

    func prepareForLaunch() {
        telemetryController.prepareForLaunch()
        Task { [notificationController] in
            await notificationController.requestAuthorization()
        }
    }

    func applyAppearance() {
        appearanceManager.applyAppearance()
    }

    func loadDirectAuthFiles() async {
        await proxyManagement.loadDirectAuthFiles()
    }

    func connectStatusBar() {
        let windowPresenter = AppKitWindowPresenter()
        let dispatcher = StatusBarCommandDispatcher(
            handlers: StatusBarCommandHandlers(
                refreshAll: { [quotaController, remoteQuotaSourceScreenModel, modeManager] in
                    // Remote sources are fetched directly from their own Management
                    // API (never through the local proxy), so including them here
                    // must never toggle or depend on the local proxy's running state.
                    async let local: Void = quotaController.refreshAll(force: true)
                    async let remote: Void = modeManager.isMonitorMode
                        ? remoteQuotaSourceScreenModel.refreshAll()
                        : ()
                    _ = await (local, remote)
                },
                refreshProvider: { [quotaController, remoteQuotaSourceScreenModel, modeManager] provider in
                    // The menu shows this provider's local *and* remote accounts under
                    // one header, so a provider-scoped refresh has to cover both —
                    // otherwise the remote rows never update from the menu at all.
                    async let local: Void = quotaController.refresh(provider: provider)
                    async let remote: Void = modeManager.isMonitorMode
                        ? remoteQuotaSourceScreenModel.refresh(provider: provider)
                        : ()
                    _ = await (local, remote)
                },
                refreshAccount: { [quotaController, remoteQuotaSourceScreenModel] account in
                    // A remote-origin account's key decodes to its source id; routing
                    // there (never through the local registry) keeps refresh scoped to
                    // that remote source and never triggers a local login/proxy call.
                    if let components = RemoteQuotaAccountIdentity.components(fromStorageKey: account.accountKey) {
                        await remoteQuotaSourceScreenModel.refresh(sourceId: components.sourceId)
                    } else {
                        await quotaController.refresh(account: account)
                    }
                },
                toggleProxy: { [proxyManagement] in
                    await proxyManagement.toggleProxy()
                },
                toggleTunnel: { [tunnel] port in
                    await tunnel.toggle(port: port)
                },
                copyText: { [pasteboard] value in
                    pasteboard.copy(value)
                },
                switchAntigravityAccount: { [antigravityAccountScreenModel] email in
                    await antigravityAccountScreenModel.switchAccount(email: email)
                },
                isAntigravityIDERunning: { [antigravityAccountScreenModel] in
                    antigravityAccountScreenModel.isIDERunning
                },
                confirmAntigravitySwitch: AntigravitySwitchConfirmationPresenter.confirm,
                selectProvider: { [menuBarSettings] provider in
                    menuBarSettings.selectProvider(provider)
                },
                openApp: { [weak statusBarManager, settingsScreenModel, windowPresenter] in
                    if settingsScreenModel.appShellPreferences.showInDock {
                        statusBarManager?.closeMenu()
                    }
                    windowPresenter.showMainWindow()
                },
                quit: { [applicationPlatform] in
                    applicationPlatform.terminate()
                },
                menuNeedsRebuild: { [weak statusBarManager] in
                    statusBarManager?.rebuildMenuInPlace()
                }
            )
        )
        statusBarManager.configureMenu(
            snapshotProvider: { [weak self] in
                guard let self else {
                    preconditionFailure("Status bar outlived application services")
                }
                return self.statusBarMenuSnapshot
            },
            commandDispatcher: dispatcher
        )
    }

    func setStatusBarStateChangeHandler(_ handler: (@MainActor () -> Void)?) {
        quotaController.setDidChangeHandler(handler)
        quotaScreenModel.setDidChangeHandler { _ in handler?() }
        proxyManagement.proxy.setDidChangeHandler { _ in handler?() }
        tunnel.setDidChangeHandler { _ in handler?() }
        menuBarSettings.setDidChangeHandler { _ in handler?() }
        modeManager.setDidChangeHandler { _ in handler?() }
        remoteQuotaSourceScreenModel.setDidChangeHandler { handler?() }
        appearanceManager.setDidChangeHandler { _ in handler?() }
        languageManager.setDidChangeHandler { _ in handler?() }
    }

    func updateStatusBar() {
        statusBarManager.updateStatusBar(
            items: quotaItems,
            colorMode: menuBarSettings.colorMode,
            quotaDisplayMode: menuBarSettings.quotaDisplayMode,
            isRunning: mergedProviderQuotas.contains { !$0.value.isEmpty },
            showMenuBarIcon: menuBarSettings.showMenuBarIcon,
            showQuota: menuBarSettings.showQuotaInMenuBar,
            appearanceMode: appearanceManager.appearanceMode,
            language: languageManager.currentLanguage
        )
    }

    func rebuildStatusBar() {
        statusBarManager.rebuildMenuInPlace()
    }

    func initializeFeatures() async {
        await tunnel.refreshInstallation()
        if modeManager.isLocalProxyMode {
            await proxyManagement.initialize()
        } else {
            await proxyManagement.loadDirectAuthFiles()
        }
        await quotaController.initialize()
        await warmupScreenModel.configure()
        if modeManager.isMonitorMode {
            await remoteQuotaSourceScreenModel.initialize()
        }
    }

    func checkForUpdatesInBackground() {
        applicationUpdateController.checkForUpdatesInBackground()
    }

    func checkForUpdates() {
        applicationUpdateController.checkForUpdates()
    }

    func startUpdatePolling() async {
        await proxyUpdatePolling.start()
    }

    func stopUpdatePolling() async {
        await proxyUpdatePolling.stop()
    }

    func shutdownOAuth() async {
        remoteQuotaSourceScreenModel.shutdown()
        await warmupScreenModel.shutdown()
        await quotaController.shutdown()
    }

    func stopTunnel() async {
        await tunnel.shutdown()
    }

    func terminateProxyOnShutdown() async {
        await proxyManagement.shutdown()
    }

    func cleanupTunnelOrphans() async {
        await tunnel.cleanupOrphans()
    }

    private var statusBarMenuSnapshot: StatusBarMenuSnapshot {
        let knownStatuses = Dictionary(
            uniqueKeysWithValues: proxyManagement.agentSetup.agentStatuses.map {
                ($0.agent, $0.installed)
            }
        )
        let installedAgents = Set(CLIAgent.allCases.filter { agent in
            knownStatuses[agent] ?? isCLIInstalled(agent)
        })
        var snapshot = quotaScreenModel.state
        snapshot.quotas = mergedProviderQuotas
        return StatusBarMenuSnapshotMapper.makeSnapshot(
            mode: modeManager.currentMode,
            proxyPort: proxyManagement.proxy.port,
            isProxyRunning: proxyManagement.proxy.proxyStatus.running,
            tunnel: tunnel.tunnelState,
            directAuthProviders: Set(proxyManagement.directAuthFiles.compactMap {
                QuotaProvider(rawValue: $0.providerID.rawValue)
            }),
            monitorAccounts: accountsScreenModel.accounts,
            quota: snapshot,
            installedAgents: installedAgents,
            activeAntigravityEmail: antigravityAccountScreenModel.snapshot.activeAccount?.email,
            menuBarPreferences: menuBarSettings.preferences,
            appearanceMode: appearanceManager.appearanceMode,
            language: languageManager.currentLanguage,
            remoteSourceNames: Dictionary(
                uniqueKeysWithValues: remoteQuotaSourceScreenModel.sources.map { ($0.id, $0.name) }
            ),
            isRemoteRefreshing: remoteQuotaSourceScreenModel.isRefreshing,
            hiddenDropdownKeys: menuBarSettings.hiddenDropdownKeys
        )
    }

    /// Local `QuotaScreenModel` quotas merged with visible remote quota-source
    /// accounts. Each remote entry is stored under a `RemoteQuotaAccountIdentity`
    /// composite key, so it can never collide with a real local account key or
    /// another remote source's account — and is never an aggregated pool.
    private var mergedProviderQuotas: [QuotaProvider: [String: ProviderQuota]] {
        guard modeManager.isMonitorMode else { return quotaScreenModel.providerQuotas }
        var merged = quotaScreenModel.providerQuotas
        for (provider, poolEntries) in remoteQuotaSourceScreenModel.visibleProviderQuotas {
            merged[provider, default: [:]].merge(poolEntries) { _, remote in remote }
        }
        return merged
    }

    /// Same-source/provider/plan summary rows (`RemoteQuotaSourceScreenModel.planAggregates`),
    /// reused only to resolve an aggregate's own pin here. Deliberately never merged into
    /// `mergedProviderQuotas` — that dictionary also feeds fetch/refresh and the dropdown
    /// account list, and an aggregate must never be mistaken for one more real account.
    private var aggregateProviderQuotas: [QuotaProvider: [String: RemoteQuotaPlanAggregate]] {
        guard modeManager.isMonitorMode else { return [:] }
        return remoteQuotaSourceScreenModel.planAggregates(mode: menuBarSettings.modelAggregationMode)
    }

    private var quotaItems: [MenuBarQuotaDisplayItem] {
        guard menuBarSettings.showQuotaInMenuBar else { return [] }

        let providerQuotas = mergedProviderQuotas
        let aggregateQuotas = aggregateProviderQuotas
        let items = menuBarSettings.selectedItems.flatMap { selectedItem -> [MenuBarQuotaDisplayItem] in
            guard let provider = selectedItem.aiProvider else { return [] }

            // A legacy remote pool selection (`accountKey == "__pool__"`) dynamically
            // expands into one item per **real** remote account currently present for
            // that source/provider, so it never collapses several accounts into a
            // single synthetic reading. New pins target one real account's own storage
            // key directly and fall through to the direct lookup below instead.
            if let sourceId = selectedItem.sourceConfigId, selectedItem.isPool {
                return poolDisplayItems(
                    selectedItem: selectedItem,
                    sourceId: sourceId,
                    provider: provider,
                    accountQuotas: providerQuotas[provider] ?? [:]
                )
            }

            // A pinned plan aggregate resolves against its own derived dictionary,
            // never the real-account one, and renders with the provider's own icon plus
            // the plan label and percentage only — no source name, no email, matching
            // how a pinned real account instead shows its own identity.
            if selectedItem.isRemote, selectedItem.isAggregate,
               let components = RemoteQuotaAggregateIdentity.components(fromStorageKey: selectedItem.accountKey) {
                return aggregatePinDisplayItem(
                    selectedItem: selectedItem,
                    provider: provider,
                    planKey: components.planKey,
                    aggregates: aggregateQuotas[provider] ?? [:]
                )
            }

            var quotaData: ProviderQuota?
            if let accountQuotas = providerQuotas[provider] {
                quotaData = resolveQuotaData(
                    for: selectedItem,
                    provider: provider,
                    accountQuotas: accountQuotas
                )
            }

            guard let quotaData else {
                // `selectedItem.accountKey` for a single-account remote pin is the internal
                // `acct::sourceId::accountKey` storage key, never fit for display. When the
                // source is disabled, deleted, or the account is hidden there is no quota to
                // resolve it against, so skip rendering rather than leak that key — the pin
                // itself stays persisted in `selectedItems` and reappears once quota is
                // visible again. Local accounts have no such internal key, so they still
                // render a placeholder row while their first fetch is pending.
                if selectedItem.isRemote { return [] }
                return [MenuBarQuotaDisplayItem(
                    id: selectedItem.id,
                    providerSymbol: provider.menuBarSymbol,
                    accountShort: selectedItem.accountKey,
                    percentage: -1,
                    provider: provider,
                    isForbidden: false,
                    quotaPair: nil
                )]
            }

            var displayPercent: Double = -1
            var quotaPair: MenuBarQuotaPair?
            if !quotaData.models.isEmpty {
                let models = quotaData.models.map { (name: $0.name, percentage: $0.percentage) }
                displayPercent = menuBarSettings.totalUsagePercent(models: models)
                if menuBarSettings.stackPairedQuotaMetrics {
                    quotaPair = MenuBarQuotaPair.resolve(for: provider, from: quotaData.models)
                }
            }

            let accountShort: String
            if let displayName = quotaData.accountDisplayName {
                accountShort = displayName
            } else if selectedItem.isRemote {
                // Never fall back to the internal storage key here either — parse the raw
                // remote account key back out, or fall back to the provider's own name.
                accountShort = RemoteQuotaAccountIdentity.components(fromStorageKey: selectedItem.accountKey)?.accountKey
                    ?? provider.displayName
            } else {
                accountShort = selectedItem.accountKey
            }

            return [MenuBarQuotaDisplayItem(
                id: selectedItem.id,
                providerSymbol: provider.menuBarSymbol,
                accountShort: accountShort,
                percentage: displayPercent,
                provider: provider,
                isForbidden: quotaData.isForbidden,
                quotaPair: quotaPair
            )]
        }
        // Pool expansion can produce more rows than one row per selected item, so the
        // configured cap is enforced here rather than by `selectedItems.count`.
        return Array(items.prefix(menuBarSettings.menuBarMaxItems))
    }

    /// Expands one legacy selected pool `MenuBarQuotaItem` (persisted before per-account
    /// remote pins existed) into one display item per **real** remote account currently
    /// present under this source/provider, found under `RemoteQuotaAccountIdentity`
    /// composite keys, via the pure, unit-tested `RemoteQuotaPoolDisplayMapper`. Never
    /// synthesizes a plan-level aggregate — a legacy pin now dynamically tracks
    /// whatever real accounts that source currently reports.
    private func poolDisplayItems(
        selectedItem: MenuBarQuotaItem,
        sourceId: String,
        provider: QuotaProvider,
        accountQuotas: [String: ProviderQuota]
    ) -> [MenuBarQuotaDisplayItem] {
        let accounts = accountQuotas.compactMap { key, quota -> RemoteQuotaPoolDisplayMapper.AccountEntry? in
            guard let components = RemoteQuotaAccountIdentity.components(fromStorageKey: key),
                  components.sourceId == sourceId else { return nil }
            // An account the user individually turned off on the Providers page is
            // excluded here — that is the only way to deselect one account out of a
            // legacy pool pin, which has no per-account entry of its own to remove.
            let accountItem = MenuBarQuotaItem(
                provider: provider.rawValue,
                accountKey: key,
                sourceConfigId: sourceId
            )
            guard menuBarSettings.poolExpansionIncludes(accountItem) else { return nil }
            return RemoteQuotaPoolDisplayMapper.AccountEntry(accountKey: components.accountKey, quota: quota)
        }
        guard !accounts.isEmpty else { return [] }

        return RemoteQuotaPoolDisplayMapper.displayItems(
            itemId: selectedItem.id,
            provider: provider,
            accounts: accounts,
            stackPairedQuotaMetrics: menuBarSettings.stackPairedQuotaMetrics,
            totalUsagePercent: menuBarSettings.totalUsagePercent
        )
    }

    /// Resolves one pinned plan aggregate against the derived `RemoteQuotaPlanAggregate`
    /// dictionary. Skips rendering (rather than showing a placeholder) when the aggregate
    /// is currently absent — same tolerance the real-account path already applies to a
    /// disabled/deleted/hidden remote pin — since the aggregate's source may have been
    /// removed/hidden or its last account may have left this plan entirely (an aggregate
    /// exists for every group with at least one account, including a single account).
    private func aggregatePinDisplayItem(
        selectedItem: MenuBarQuotaItem,
        provider: QuotaProvider,
        planKey: String,
        aggregates: [String: RemoteQuotaPlanAggregate]
    ) -> [MenuBarQuotaDisplayItem] {
        guard let aggregate = aggregates[selectedItem.accountKey] else { return [] }

        return [RemoteQuotaAggregatePinDisplayMapper.displayItem(
            itemId: selectedItem.id,
            provider: provider,
            planKey: planKey,
            aggregate: aggregate,
            totalUsagePercent: menuBarSettings.totalUsagePercent
        )]
    }

    /// Direct dictionary lookup for both local accounts and single-account remote pins
    /// (whose `accountKey` is the exact `RemoteQuotaAccountIdentity` storage key already
    /// present in `accountQuotas`). Only legacy pool-style items (`selectedItem.isPool`)
    /// skip this — those are always intercepted earlier in `quotaItems` and resolved via
    /// `poolDisplayItems` instead, since they have no single storage key to look up.
    private func resolveQuotaData(
        for selectedItem: MenuBarQuotaItem,
        provider: QuotaProvider,
        accountQuotas: [String: ProviderQuota]
    ) -> ProviderQuota? {
        if selectedItem.isPool {
            return nil
        }

        if let quotaData = accountQuotas[selectedItem.accountKey] {
            return quotaData
        }

        let cleanKey = selectedItem.accountKey.hasSuffix(".json")
            ? String(selectedItem.accountKey.dropLast(".json".count))
            : selectedItem.accountKey
        if let quotaData = accountQuotas[cleanKey] {
            return quotaData
        }

        if provider == .codex {
            var filenameKey = selectedItem.accountKey
            if filenameKey.hasPrefix("codex-") {
                filenameKey.removeFirst("codex-".count)
            }
            if filenameKey.hasSuffix(".json") {
                filenameKey.removeLast(".json".count)
            }
            return accountQuotas[filenameKey]
        }
        if provider == .copilot, selectedItem.accountKey.hasPrefix("github-copilot-") {
            var filenameKey = selectedItem.accountKey
            filenameKey.removeFirst("github-copilot-".count)
            if filenameKey.hasSuffix(".json") {
                filenameKey.removeLast(".json".count)
            }
            guard !filenameKey.isEmpty else { return nil }
            return accountQuotas[filenameKey]
        }
        return nil
    }
}
