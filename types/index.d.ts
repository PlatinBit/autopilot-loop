// State contract: the last autopilot state the status poll saw (see hooks/register.ts).
export type Finish = { running: string; done: string }

declare module 'claude-code' {
  interface PluginState {
    autopilot: { finish: Finish }
  }
}
