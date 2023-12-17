import * as path from "path";

import { simpleGit } from "simple-git";

import { incrementVersionFile } from "./incrementVersionFile";
import { Context } from "./interfaces";

interface MainArguments {
  context: Context;
  getInput(key: string): string;
  /* eslint-disable  @typescript-eslint/no-explicit-any */
  log(message?: any, ...optionalParams: any[]): void;
  setFailed(message: string): void;
}

export async function main({
  context,
  getInput,
  log,
  setFailed,
}: MainArguments): Promise<void> {
  try {
    const eventName = context.eventName;
    if (!["push", "workflow_dispatch"].includes(eventName)) {
      log(`Skipping increment-version for event ${eventName}`);
      return;
    }

    const actor = context.actor;
    const commitMessage = getInput("commitMessage");
    const authorNameInput = getInput("authorName");
    const authorName = authorNameInput !== "" ? authorNameInput : actor;
    const authorEmailInput = getInput("authorEmail");
    const authorEmail =
      authorEmailInput !== ""
        ? authorEmailInput
        : `github-actions-${actor}@users.noreply.github.com`;
    const repoPath = getInput("repoPath");
    const versionFilePath = getInput("versionFilePath");
    const versionFilePathFull = path.join(repoPath, versionFilePath);
    await incrementVersionFile({
      versionFilePath: versionFilePathFull,
      versionFormat: getInput("versionFormat"),
    });

    const git = simpleGit(repoPath);
    await git.add(versionFilePathFull);
    await git.commit(commitMessage, {
      "--author": `${authorName} <${authorEmail}>`,
    });
    const remotes = await git.getRemotes();
    if (remotes.length > 0) {
      await git.push();
    }
  } catch (error: any) {
    setFailed(error.message);
    throw error;
  }
}
