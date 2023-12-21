import * as path from "path";

import { simpleGit } from "simple-git";

import { incrementVersionFile } from "./incrementVersionFile";
import { stageFilesAndCommitAndPush } from "github-action-pack-toolkit";
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
    const branchInput = getInput("branch");
    const branch = branchInput !== "" ? branchInput : undefined;
    const remoteInput = getInput("remote");
    const remote = remoteInput !== "" ? remoteInput : undefined;
    const repoPathInput = getInput("repoPath");
    const repoPath = repoPathInput !== "" ? repoPathInput : "./";
    const versionFilePath = getInput("versionFilePath");
    const versionFilePathFull = path.join(repoPath, versionFilePath);
    await incrementVersionFile({
      versionFilePath: versionFilePathFull,
      versionFormat: getInput("versionFormat"),
    });

    await stageFilesAndCommitAndPush({
      authorEmail,
      authorName,
      branch,
      commitMessage,
      remote,
      repoPath,
      requiredFiles: [versionFilePath],
    });
  } catch (error: any) {
    setFailed(error.message);
    throw error;
  }
}
