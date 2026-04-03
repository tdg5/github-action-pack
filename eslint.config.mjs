import eslint from "@eslint/js";
import tseslint from "typescript-eslint";
import prettierConfig from "eslint-config-prettier";
import prettierPlugin from "eslint-plugin-prettier/recommended";
import jest from "eslint-plugin-jest";
import importX from "eslint-plugin-import-x";

export default tseslint.config(
  {
    ignores: ["**/node_modules/**", "**/dist/**", "actions/**"],
  },
  eslint.configs.recommended,
  ...tseslint.configs.recommended,
  prettierConfig,
  prettierPlugin,
  {
    files: ["packages/**/src/**/*.ts"],
    plugins: {
      "import-x": importX,
    },
    languageOptions: {
      parserOptions: {
        projectService: true,
      },
    },
    rules: {
      curly: ["error", "all"],
    },
  },
  {
    files: ["packages/**/src/**/*.test.ts"],
    ...jest.configs["flat/recommended"],
  },
);
