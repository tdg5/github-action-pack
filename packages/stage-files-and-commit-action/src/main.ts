import { stageFilesAndCommit } from "github-action-pack-toolkit";
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
      log(`Skipping stage-files-and-commit for event ${eventName}`);
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
    const optionalFilePathsInput = getInput("optionalFilePaths");
    const optionalFiles = optionalFilePathsInput
      .split("\n")
      .filter((filePath: string) => filePath.length > 0);
    const repoPathInput = getInput("repoPath");
    const repoPath = repoPathInput !== "" ? repoPathInput : "./";
    const requiredFilePathsInput = getInput("requiredFilePaths");
    const requiredFiles = requiredFilePathsInput
      .split("\n")
      .filter((filePath: string) => filePath.length > 0);

    await stageFilesAndCommit({
      authorEmail,
      authorName,
      commitMessage,
      optionalFiles,
      repoPath,
      requiredFiles,
    });
  } catch (error: any) {
    setFailed(error.message);
    throw error;
  }
}
