import { escapePattern } from "./regexp";

interface FormatConfiguration {
  alphaSegmentPrefix: string;
  alphaSegmentSuffix: string;
  alphaSegmentToken: string;
  alphaSegmentVersionMinLength: number;
}

const FORMAT_CONFIGURATIONS: { [key: string]: FormatConfiguration } = {
  default: {
    alphaSegmentPrefix: "-",
    alphaSegmentSuffix: "-",
    alphaSegmentToken: "alpha",
    alphaSegmentVersionMinLength: 3,
  },
  python: {
    alphaSegmentPrefix: "",
    alphaSegmentSuffix: "",
    alphaSegmentToken: "a",
    alphaSegmentVersionMinLength: 0,
  },
};

const lastSegmentMatcher: RegExp = /\d+$/;

function padWithLeadingZeroes(number: number, minLength: number): string {
  return number.toString().padStart(minLength, "0");
}

interface VersionFormatConstructorArgs {
  alphaSegmentVersionMinLength: number;
  alphaSegmentPrefix: string;
  alphaSegmentSuffix: string;
  alphaSegmentToken: string;
}

class VersionFormat {
  alphaSegmentMatcher: RegExp;
  alphaSegmentPrefix: string;
  alphaSegmentSuffix: string;
  alphaSegmentToken: string;
  alphaSegmentVersionMinLength: number;

  constructor({
    alphaSegmentPrefix,
    alphaSegmentSuffix,
    alphaSegmentToken,
    alphaSegmentVersionMinLength,
  }: VersionFormatConstructorArgs) {
    this.alphaSegmentPrefix = alphaSegmentPrefix;
    this.alphaSegmentSuffix = alphaSegmentSuffix;
    this.alphaSegmentToken = alphaSegmentToken;
    this.alphaSegmentVersionMinLength = alphaSegmentVersionMinLength;
    const pattern: string = escapePattern(
      `${alphaSegmentPrefix}${alphaSegmentToken}${alphaSegmentSuffix}`,
    );
    this.alphaSegmentMatcher = new RegExp(`${pattern}\\d+$`);
  }

  incrementVersion(version: string): string {
    const sanitizedVersion = version.trim();
    const parts = sanitizedVersion.split(".");
    const lastPart = parts[parts.length - 1];

    if (this.isAlpha(sanitizedVersion)) {
      const alphaSegmentMatch = lastSegmentMatcher.exec(lastPart) || ["0"];
      const alphaSegmentVersion = alphaSegmentMatch[0];
      const newAlphaVersion = parseInt(alphaSegmentVersion) + 1;
      const newAlphaVersionStr = padWithLeadingZeroes(
        newAlphaVersion,
        this.alphaSegmentVersionMinLength,
      );
      return sanitizedVersion.replace(lastSegmentMatcher, newAlphaVersionStr);
    }

    parts[parts.length - 1] = (parseInt(lastPart) + 1).toString();
    const alphaVersion = padWithLeadingZeroes(
      0,
      this.alphaSegmentVersionMinLength,
    );
    const alphaSegment = [
      this.alphaSegmentPrefix,
      this.alphaSegmentToken,
      this.alphaSegmentSuffix,
      alphaVersion,
    ].join("");
    return parts.join(".") + alphaSegment;
  }

  isAlpha(version: string): boolean {
    return this.alphaSegmentMatcher.test(version);
  }
}

interface IncrementVersionArgs {
  format: string;
  version: string;
}

export const incrementVersion = ({
  format,
  version,
}: IncrementVersionArgs): string => {
  const theFormat = format in FORMAT_CONFIGURATIONS ? format : "default";
  const versionFormat = new VersionFormat(FORMAT_CONFIGURATIONS[theFormat]);
  return versionFormat.incrementVersion(version);
};
