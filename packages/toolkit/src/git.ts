import { simpleGit, SimpleGit } from "simple-git";

interface StageFilesArgs {
  git?: SimpleGit;
  optionalFiles?: string[];
  repoPath: string;
  requiredFiles?: string[];
}

export const stageFiles = async ({
  git,
  optionalFiles,
  repoPath,
  requiredFiles,
}: StageFilesArgs): Promise<void> => {
  const _git = git || simpleGit({ baseDir: repoPath });
  const _requiredFiles = requiredFiles || [];
  const files: string[] = _requiredFiles.concat(optionalFiles || []);
  if (files.length === 0) {
    return;
  }
  await _git.add(files);
  const status = await _git.status();
  const staged = new Set(status.staged);
  _requiredFiles.forEach((requiredFile) => {
    if (!staged.has(requiredFile)) {
      throw Error(`Required file ${requiredFile} had no differences to stage`);
    }
  });
};

interface StageFilesAndCommitArgs extends StageFilesArgs {
  authorEmail: string;
  authorName: string;
  commitMessage: string;
}

export const stageFilesAndCommit = async ({
  authorEmail,
  authorName,
  commitMessage,
  git,
  optionalFiles,
  repoPath,
  requiredFiles,
}: StageFilesAndCommitArgs): Promise<void> => {
  const _git: SimpleGit = git || simpleGit({ baseDir: repoPath });
  await stageFiles({ git: _git, optionalFiles, repoPath, requiredFiles });

  // Prefer not to set configs, but we can't commit if the configs don't exist
  const userEmailConfig = await _git.getConfig("user.email");
  if (userEmailConfig.values.length === 0) {
    await _git.addConfig("user.email", authorEmail);
  }
  const userNameConfig = await _git.getConfig("user.name");
  if (userNameConfig.values.length === 0) {
    await _git.addConfig("user.name", authorName);
  }

  const _requiredFiles = requiredFiles || [];
  const files: string[] = _requiredFiles.concat(optionalFiles || []);
  await _git.commit(commitMessage, files, { "--author": `${authorName} <${authorEmail}>` });
};

interface StageFilesAndCommitAndPushArgs extends StageFilesAndCommitArgs {
  branch?: string;
  remote?: string;
}

export const stageFilesAndCommitAndPush = async({
  authorEmail,
  authorName,
  branch,
  commitMessage,
  git,
  optionalFiles,
  remote,
  repoPath,
  requiredFiles,
}: StageFilesAndCommitAndPushArgs) => {
  const _git: SimpleGit = git || simpleGit({ baseDir: repoPath });
  await stageFilesAndCommit({
    authorEmail,
    authorName,
    commitMessage,
    git: _git,
    optionalFiles,
    repoPath,
    requiredFiles,
   });
  const remotes = _git.getRemotes();
  if (remote && branch) {
    await _git.push(remote, branch)
  } else {
    await _git.push()
  }
};
