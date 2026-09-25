import * as vscode from 'vscode'
import { externalConfigPath, loadConfigSource } from './config.ts'
import { providerSelectionKey, selectedProvider } from './providerSelection.ts'
import { Generations, isExpectedCancellation, repositoryForContext } from './generation.ts'
import {
  listProviders,
  generate as generateWithMoonBit,
  type ConfigurationInput,
} from './runtime.ts'

interface GitRepository {
  rootUri: vscode.Uri
  inputBox: { value: string }
}

interface GitApi {
  repositories: GitRepository[]
}

async function gitApi(): Promise<GitApi> {
  const extension = vscode.extensions.getExtension('vscode.git')

  if (!extension) {
    throw new Error('The built-in VS Code Git extension is unavailable.')
  }

  const exports = extension.isActive ? extension.exports : await extension.activate()

  return exports.getAPI(1) as GitApi
}

async function chooseRepository(context?: unknown): Promise<GitRepository | undefined> {
  const repositories = (await gitApi()).repositories ?? []

  if (repositories.length === 0) {
    throw new Error('No Git repository is open.')
  }

  const matched = repositoryForContext(repositories, context)

  if (matched) {
    return matched
  }

  if (repositories.length === 1) {
    return repositories[0]
  }

  const selected = await vscode.window.showQuickPick(
    repositories.map((repository) => ({
      label: repository.rootUri.path.split('/').filter(Boolean).pop() || repository.rootUri.fsPath,
      description: repository.rootUri.fsPath,
      repository,
    })),
    { placeHolder: 'Select the repository whose staged changes should be summarized' },
  )

  return selected?.repository
}

function configPath(): string {
  const path = vscode.workspace.getConfiguration('genmit').get<string>('configPath')

  if (path === undefined) {
    throw new Error('Missing registered setting: genmit.configPath')
  }

  return path.trim()
}

let providerState: vscode.Memento | undefined

function state(): vscode.Memento {
  if (!providerState) {
    throw new Error('genmit is not active')
  }

  return providerState
}

async function generationInput(repository: GitRepository) {
  const path = configPath()

  const root = repository.rootUri.fsPath

  const config: ConfigurationInput = {
    config_source: await loadConfigSource(root, path),
  }

  const providers = listProviders(config.config_source)

  const selectionKey = providerSelectionKey(root, externalConfigPath(root, path))

  config.provider = selectedProvider(providers, state().get<string>(selectionKey))

  return { root, config, providers, selectionKey }
}

async function selectProvider(context?: unknown): Promise<void> {
  const repository = await chooseRepository(context)

  if (!repository) {
    return
  }

  const { config, providers, selectionKey } = await generationInput(repository)

  const name = await vscode.window.showQuickPick(
    [
      {
        label: 'Use configuration default',
        description: 'Follow the default provider in the active configuration',
        name: undefined,
      },
      ...providers.map((provider) => ({
        label: provider.name,
        description: `${provider.kind}${provider.name === config.provider ? ' — current' : ''}`,
        name: provider.name,
      })),
    ],
    {
      title: 'genmit: Select Provider',
      placeHolder: 'Select a named provider from the active configuration',
    },
  )

  if (!name) {
    return
  }

  await state().update(selectionKey, name.name)
}

const generations = new Generations()

async function generate(status: vscode.StatusBarItem, context?: unknown): Promise<void> {
  const repository = await chooseRepository(context)

  if (!repository) {
    return
  }

  const session = generations.start(repository)
  status.text = '$(sync~spin) Generating commit message...'
  status.show()

  try {
    const { root, config } = await generationInput(repository)

    const result = await generateWithMoonBit(root, config, session.controller.signal)

    if (!session.isCurrent()) {
      return
    }

    const message = result.message

    if (session.canApply()) {
      repository.inputBox.value = message
    } else {
      const document = await vscode.workspace.openTextDocument({
        language: 'plaintext',
        content: message,
      })

      await vscode.window.showTextDocument(document, { preview: false })

      void vscode.window.showInformationMessage(
        'The commit message was edited during generation. The generated message was opened in a separate editor.',
      )
    }
  } catch (error) {
    if (!isExpectedCancellation(error, session.controller.signal)) {
      throw error
    }
  } finally {
    session.finish()

    if (!generations.hasActive()) {
      status.hide()
      status.text = ''
    }
  }
}

function report(
  action: (context?: unknown) => Promise<void>,
): (context?: unknown) => Promise<void> {
  return async (context) => {
    try {
      await action(context)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)

      await vscode.window.showErrorMessage(`genmit: ${message}`)
    }
  }
}

export function activate(context: vscode.ExtensionContext): void {
  providerState = context.globalState
  const generationStatus = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 1000)
  generationStatus.command = 'genmit.cancelGeneration'
  generationStatus.tooltip = 'Cancel all active commit-message generations'

  context.subscriptions.push(
    generationStatus,
    vscode.commands.registerCommand(
      'genmit.generate',
      report((commandContext) => generate(generationStatus, commandContext)),
    ),
    vscode.commands.registerCommand('genmit.selectProvider', report(selectProvider)),
    vscode.commands.registerCommand('genmit.cancelGeneration', () => generations.cancelAll()),
  )
}

export function deactivate(): void {
  generations.cancelAll()
  providerState = undefined
}
