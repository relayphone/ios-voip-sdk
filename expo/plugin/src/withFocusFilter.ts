import {
  type ConfigPlugin,
  IOSConfig,
  withEntitlementsPlist,
  withInfoPlist,
  withXcodeProject,
  type XcodeProject,
} from "expo/config-plugins.js";
import { copyFileSync, existsSync, mkdirSync } from "fs";
import { basename, join, resolve } from "path";

const ERROR_MSG_PREFIX =
  "An error occurred while configuring the Focus filter. ";

/** The app's group of Focus filter sources, inside its own group. */
const SOURCES_GROUP = "FocusFilter";

const APP_GROUPS = "com.apple.security.application-groups";

export type FocusFilterOption = {
  /**
   * The App Group in which the app's Focus filter records its state, such as
   * `group.com.example.calls`: the `appGroup` of the filter's `FocusFilterStore`. The plugin adds
   * it to the app's App Groups.
   */
  appGroup: string;
  /**
   * Swift files, relative to the project root, that declare the app's Focus filter, a
   * `CallFocusFilter` with its parameters and settings. Prebuild copies them to
   * `ios/<app>/FocusFilter` and compiles them in the app, where the system runs the filter. Leave
   * it out when an App Intents extension of your own declares the filter.
   */
  sources?: string[];
};

/**
 * Copies the Focus filter's sources into the iOS project, and compiles them in the app target.
 * Running it again replaces the copies and leaves the project as it is.
 */
export function addFocusFilterSources(
  project: XcodeProject,
  {
    projectRoot,
    projectName,
    sources,
  }: { projectRoot: string; projectName: string; sources: string[] },
): XcodeProject {
  const names = sources.map((source) => basename(source));
  if (new Set(names).size !== names.length) {
    throw new Error(
      `${ERROR_MSG_PREFIX}"focusFilter.sources" have the same file name twice.`,
    );
  }
  const directory = join(projectRoot, "ios", projectName, SOURCES_GROUP);
  mkdirSync(directory, { recursive: true });
  const groupName = `${projectName}/${SOURCES_GROUP}`;
  IOSConfig.XcodeUtils.ensureGroupRecursively(project, groupName);
  for (const source of sources) {
    const path = resolve(projectRoot, source);
    if (!path.endsWith(".swift")) {
      throw new Error(`${ERROR_MSG_PREFIX}"${source}" isn't a Swift file.`);
    }
    if (!existsSync(path)) {
      throw new Error(
        `${ERROR_MSG_PREFIX}Focus filter source not found: ${path}`,
      );
    }
    copyFileSync(path, join(directory, basename(path)));
    project = IOSConfig.XcodeUtils.addBuildSourceFileToGroup({
      filepath: `${groupName}/${basename(path)}`,
      groupName,
      project,
    });
  }
  return project;
}

/**
 * Lets the module read the app's Focus filter state: the module's podspec adds ios-voip-sdk's
 * `Focus` subspec from the Podfile properties, the app joins the filter's App Group, whose
 * identifier the module reads from the Info.plist, and prebuild compiles the filter's sources in
 * the app.
 */
export const withFocusFilter: ConfigPlugin<{
  focusFilter?: FocusFilterOption;
}> = (config, { focusFilter }) => {
  if (!focusFilter) return config;
  const { appGroup, sources } = focusFilter;
  if (!/^group\.[A-Za-z0-9.-]+$/.test(appGroup ?? "")) {
    throw new Error(
      `${ERROR_MSG_PREFIX}"focusFilter.appGroup" must be an App Group identifier, such as ` +
        `"group.com.example.calls".`,
    );
  }
  config = withInfoPlist(config, (config) => {
    config.modResults.VoIPConversationsFocusAppGroup = appGroup;
    return config;
  });
  config = withEntitlementsPlist(config, (config) => {
    const groups = config.modResults[APP_GROUPS];
    const existing = Array.isArray(groups)
      ? groups.filter((group): group is string => typeof group === "string")
      : [];
    config.modResults[APP_GROUPS] = [...new Set([...existing, appGroup])];
    return config;
  });
  if (!sources?.length) return config;
  return withXcodeProject(config, (config) => {
    const projectName = config.modRequest.projectName;
    if (!projectName) {
      throw new Error(
        `${ERROR_MSG_PREFIX}Unable to find the iOS project name.`,
      );
    }
    config.modResults = addFocusFilterSources(config.modResults, {
      projectRoot: config.modRequest.projectRoot,
      projectName,
      sources,
    });
    return config;
  });
};
