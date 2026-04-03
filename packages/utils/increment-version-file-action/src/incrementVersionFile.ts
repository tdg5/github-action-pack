import { incrementVersion } from "github-action-pack-toolkit";
import { promises as fs } from "fs";

interface IncrementVersionFileArguments {
  versionFilePath: string;
  versionFormat: string;
}

export type { IncrementVersionFileArguments };

const incrementVersionFile = async ({
  versionFilePath,
  versionFormat,
}: IncrementVersionFileArguments): Promise<void> => {
  const currentVersion = await fs.readFile(versionFilePath, "utf-8");
  const newVersion = incrementVersion({
    format: versionFormat,
    version: currentVersion,
  });
  await fs.writeFile(versionFilePath, newVersion);
};

export { incrementVersionFile };
