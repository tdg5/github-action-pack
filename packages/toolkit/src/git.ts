import { simpleGit, SimpleGit } from "simple-git";

interface StageFilesArgs {
  optionalFiles?: string[];
  repoDir: string;
  requiredFiles?: string[];
}

export const stageFiles = async ({
  optionalFiles,
  repoDir,
  requiredFiles,
}: StageFilesArgs): Promise<void> => {
  const _requiredFiles = requiredFiles || [];
  const files: string[] = _requiredFiles.concat(optionalFiles || []);
  if (files.length === 0) {
    return;
  }
  const git: SimpleGit = simpleGit({ baseDir: repoDir });
  await git.add(files);
  const status = await git.status();
  const staged = new Set(status.staged);
  _requiredFiles.forEach((requiredFile) => {
    if (!staged.has(requiredFile)) {
      throw Error(`Required file ${requiredFile} had no differences to stage`);
    }
  });
};
