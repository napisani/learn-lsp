import * as fs from 'node:fs';
import * as path from 'node:path';
import type {
	AnnotateRangeParams,
	AnnotationResult,
	BaseRequestParams,
	EditAppliedResult,
	EditSelectionParams,
	ExplainSelectionParams,
	ExplanationResult,
	GenerateWalkthroughParams,
	QuestionSelectionParams,
	SearchLocationsParams,
	SearchLocationsResult,
	AgentSessionOutputParams,
	ListSkillsResult,
	WalkthroughResult,
} from '../../protocol';
import type { AgentRuntime } from '../agent';

export class DevelopmentAgentRuntime implements AgentRuntime {
	explainSelection(params: ExplainSelectionParams): ExplanationResult {
		return {
			kind: 'explanation',
			markdown: [
				'## Explanation',
				'',
				`Development agent runtime response for **${params.language}**.`,
				renderLens(params.lens),
				renderPreview('Selected preview', params.selectedText),
				contextSummary(params),
			].join('\n'),
		};
	}

	questionSelection(params: QuestionSelectionParams): ExplanationResult {
		return {
			kind: 'explanation',
			markdown: [
				'## Answer',
				'',
				`Development agent runtime response for **${formatLanguage(params.language)}**.`,
				'',
				`Question: ${params.question}`,
				renderLens(params.lens),
				renderPreview('Selected preview', params.selectedText),
				contextSummary(params),
			].join('\n'),
		};
	}

	editSelection(_params: EditSelectionParams): EditAppliedResult {
		return {
			kind: 'edit_applied',
			summary: 'Development runtime simulated the requested edit.',
		};
	}

	annotateRange(params: AnnotateRangeParams): AnnotationResult {
		const baseLine = params.visibleRange?.startLine ?? params.range?.startLine ?? 1;
		const maxAnnotations = params.maxAnnotations ?? 3;
		const annotations = params.scopeText
			.split(/\r?\n/)
			.map((line, index) => ({ line, index }))
			.filter(({ line }) => line.trim().length > 0)
			.slice(0, maxAnnotations)
			.map(({ line, index }) => ({
				range: {
					startLine: baseLine + index,
					startCharacter: 1,
					endLine: baseLine + index,
					endCharacter: Math.max(1, line.length),
				},
				text: `Development annotation for ${formatLanguage(params.language)}: ${line.trim()}`,
				severity: 'info' as const,
				detailMarkdown: [
					'## Annotation detail',
					'',
					`Development annotation for ${formatLanguage(params.language)}.`,
					'',
					`Line: \`${line.trim()}\``,
				].join('\n'),
			}));

		return {
			kind: 'annotations',
			annotations,
		};
	}

	searchLocations(params: SearchLocationsParams): SearchLocationsResult {
		return {
			kind: 'locations',
			locations: [
				{
					filePath: params.filePath,
					startLine: params.range?.startLine ?? params.cursor.line,
					startCharacter: params.range?.startCharacter ?? params.cursor.character,
					explanation: `Development search result for: ${params.query}`,
				},
			],
		};
	}

	agentCancel(params: BaseRequestParams): ExplanationResult {
		return {
			kind: 'explanation',
			markdown: [
				'## Vantage Agent',
				'',
				'Development agent runtime cancel.',
				'',
				`Workspace: \`${params.workspaceRoot ?? params.filePath}\``,
			].join('\n'),
		};
	}

	agentSessionReset(params: BaseRequestParams): ExplanationResult {
		return {
			kind: 'explanation',
			markdown: [
				'## Vantage Agent Session',
				'',
				'Development agent runtime session reset.',
				'',
				`Workspace: \`${params.workspaceRoot ?? params.filePath}\``,
			].join('\n'),
		};
	}

	agentSessionStatus(params: BaseRequestParams): ExplanationResult {
		return {
			kind: 'explanation',
			markdown: [
				'## Vantage Agent Session',
				'',
				'Development agent runtime session status.',
				'',
				`Workspace: \`${params.workspaceRoot ?? params.filePath}\``,
				'- Turn count: 0',
			].join('\n'),
		};
	}

	agentSessionOutput(params: AgentSessionOutputParams): ExplanationResult {
		return {
			kind: 'explanation',
			markdown: [
				'## Vantage Session Output',
				'',
				'### development · completed',
				'',
				`Workspace: \`${params.workspaceRoot ?? params.filePath}\``,
				params.raw ? '' : undefined,
				params.raw ? '#### Raw' : undefined,
				params.raw ? 'Development runtime has no raw agent events.' : undefined,
			].filter((line): line is string => line !== undefined).join('\n'),
		};
	}

	generateWalkthrough(params: GenerateWalkthroughParams): WalkthroughResult {
		const root = params.workspaceRoot && params.workspaceRoot.trim().length > 0 ? params.workspaceRoot : path.dirname(params.filePath);
		const relativeFile = path.relative(root, params.filePath) || params.filePath;
		const walkthroughDir = path.join(root, '.vantage');
		const walkthroughPath = path.join(walkthroughDir, 'walkthrough.json');
		fs.mkdirSync(walkthroughDir, { recursive: true });
		fs.writeFileSync(walkthroughPath, JSON.stringify({
			version: 1,
			pointers: [
				{
					file: relativeFile.split(path.sep).join('/'),
					line: params.cursor.line,
					description: `Development walkthrough result for: ${params.prompt}`,
				},
			],
		}, null, 2));
		return {
			kind: 'walkthrough',
			path: walkthroughPath,
			pointerCount: 1,
		};
	}

	listSkills(): ListSkillsResult {
		return {
			kind: 'skills',
			skills: [
				{
					name: 'development-skill',
					description: 'Development runtime placeholder skill.',
					filePath: '/development/SKILL.md',
					source: 'development',
				},
			],
		};
	}
}

function formatLanguage(language: string): string {
	if (language.length === 0) {
		return 'Unknown';
	}

	return `${language[0].toUpperCase()}${language.slice(1)}`;
}

function renderLens(lens: { mode: string; text?: string } | undefined): string {
	if (!lens) {
		return 'Lens: general';
	}

	return lens.text ? `Lens: ${lens.mode} - ${lens.text}` : `Lens: ${lens.mode}`;
}

function renderPreview(label: string, text: string): string {
	const preview = text.trim().split(/\r?\n/).slice(0, 3).join('\n');
	return `${label}:\n\`\`\`\n${preview}\n\`\`\``;
}

function contextSummary(params: { filePath: string; git?: { branch?: string; touchedFiles?: string[] } }): string {
	const parts = [`file ${params.filePath}`];

	if (params.git?.branch) {
		parts.push(`branch ${params.git.branch}`);
	}

	if (params.git?.touchedFiles?.length) {
		parts.push(`${params.git.touchedFiles.length} touched files`);
	}

	return `Context: ${parts.join(', ')}.`;
}
