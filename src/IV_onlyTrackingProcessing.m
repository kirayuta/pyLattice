% postprocessing after tracking
% from runTrackProcessing3D

function IV_onlyTrackingProcessing()
disp('--------------------------------------------------------------')
disp('IV_onlyTrackingProcessing(): start...')

buffer = [3 3];
preprocess = true; %opts.Preprocess;
postprocess = true; %opts.Postprocess;
BufferAll = false; %opts.BufferAll
WindowSize = [];

inputParametersMap = readParam();

resultsPath = inputParametersMap('outputDataFolder');
detectionFilename = inputParametersMap('ch1_detectionFilename');
trackingFilename = inputParametersMap('ch1_trackingFilename');
framerate_s = str2num(inputParametersMap('framerate_msec'))/1000;
movieLength = str2num(inputParametersMap('movieLength'));


dfile = [resultsPath '/' detectionFilename];


if exist(dfile, 'file')==2
    detection = load(dfile);
else
    fprintf('runTrackProcessing: no detection data found for %s\n', getShortPath(data));
    return
end
frameInfo = detection.frameInfo;
sigmaV = frameInfo(1).s;

nFrames = numel(frameInfo);
frameIdx = 1:nFrames;

alpha = 0.05;
kLevel = norminv(1-alpha/2.0, 0, 1); % ~2 std above background

%=================================
% Identify master/slave channels
%=================================
%nCh = length(data.channels);
nCh = 1; % joh: the channels get processed sequentially anyways

% for k = 1:nCh
%     data.framePaths{k} = data.framePaths{k}(frameIdx);
% end

% data.maskPaths = data.maskPaths(frameIdx);
% data.framerate = data.framerate*(frameIdx(2)-frameIdx(1));
% movieLength = length(data.framePaths{1});

sigma = sigmaV(1,:);
% w3x = ceil(3*sigma(1));
w4x = ceil(4*sigma(1));
% w4z = ceil(4*sigma(2));

%======================================================================
% Read and convert tracker output
%======================================================================

tPath = [resultsPath '/' trackingFilename];
if exist(tPath, 'file')==2
    trackinfo = load(tPath);
    trackinfo = trackinfo.tracksFinal;
    nTracks = length(trackinfo);
else
    fprintf('runTrackProcessing: no tracking data found for %s\n', getShortPath(data));
    return;
end


%======================================================================
% Preprocessing
%======================================================================
if preprocess
    % Remove single-frame tracks
    bounds = arrayfun(@(i) i.seqOfEvents([1 end],1), trackinfo, 'unif', 0);
    rmIdx = diff(horzcat(bounds{:}), [], 1)==0;
    trackinfo(rmIdx) = [];
    nTracks = size(trackinfo, 1);
    
    %----------------------------------------------------------------------
    % Merge compound tracks with overlapping ends/starts
    %----------------------------------------------------------------------
    for i = 1:nTracks
        nSeg = size(trackinfo(i).tracksFeatIndxCG,1);
        if nSeg > 1
            seqOfEvents = trackinfo(i).seqOfEvents;
            tracksCoordAmpCG = trackinfo(i).tracksCoordAmpCG;
            tracksFeatIndxCG = trackinfo(i).tracksFeatIndxCG;
            
            rmIdx = [];
            for s = 1:nSeg
                iEvent = seqOfEvents(seqOfEvents(:,3)==s,:);
                parentSeg = iEvent(2,4);
                parentStartIdx = seqOfEvents(seqOfEvents(:,2)==1 & seqOfEvents(:,3)==parentSeg,1);
                
                % conditions for merging:
                % -current segment merges at end
                % -overlap between current segment and 'parent' it merges into: 1 frame
                if ~isnan(iEvent(2,4)) && iEvent(2,1)-1==parentStartIdx
                    
                    % replace start index of parent with start index of current segment
                    seqOfEvents(seqOfEvents(:,3)==parentSeg & seqOfEvents(:,2)==1,1) = iEvent(1,1);
                    % remove current segment
                    seqOfEvents(seqOfEvents(:,3)==s,:) = [];
                    % assign segments that merge/split from current to parent
                    seqOfEvents(seqOfEvents(:,4)==s,4) = parentSeg;
                    
                    % use distance of points at overlap to assign
                    xMat = tracksCoordAmpCG(:,1:8:end);
                    yMat = tracksCoordAmpCG(:,2:8:end);
                    
                    % indexes in the 8-step matrices
                    iMat = repmat(1:size(xMat,2), [nSeg 1]).*~isnan(xMat);
                    
                    overlapIdx = setdiff(intersect(iMat(parentSeg,:), iMat(s,:)), 0);
                    if overlapIdx(1)>1 && overlapIdx(end)<seqOfEvents(end,1) && overlapIdx(1)~=(iEvent(1,1)-seqOfEvents(1,1)+1)
                        idx = [overlapIdx(1)-1 overlapIdx(end)+1];
                        if isnan(xMat(s,idx(1)))
                            idx(1) = overlapIdx(1);
                        end
                        if isnan(xMat(parentSeg,idx(2)))
                            idx(2) = overlapIdx(end);
                        end
                    elseif overlapIdx(1)==1 || overlapIdx(1)==(iEvent(1,1)-seqOfEvents(1,1)+1)
                        idx = [overlapIdx(1) overlapIdx(end)+1];
                        if isnan(xMat(parentSeg,idx(2)))
                            idx(2) = overlapIdx(end);
                        end
                    else
                        idx = [overlapIdx(1)-1 overlapIdx(end)];
                        if isnan(xMat(s,idx(1)))
                            idx(1) = overlapIdx(1);
                        end
                    end
                    xRef = interp1(idx, [xMat(s,idx(1)) xMat(parentSeg,idx(2))], overlapIdx);
                    yRef = interp1(idx, [yMat(s,idx(1)) yMat(parentSeg,idx(2))], overlapIdx);
                    
                    d = sqrt((xMat([s parentSeg],overlapIdx)-xRef).^2 + (yMat([s parentSeg],overlapIdx)-yRef).^2);
                    % remove overlap
                    rm = [s parentSeg];
                    rm = rm(d~=min(d));
                    iMat(rm,overlapIdx) = 0;
                    tracksCoordAmpCG(rm,(overlapIdx-1)*8+(1:8)) = NaN;
                    tracksFeatIndxCG(rm,overlapIdx) = 0;
                    tracksFeatIndxCG(parentSeg,iMat(s,:)~=0) = tracksFeatIndxCG(s,iMat(s,:)~=0);
                    
                    % concatenate segments
                    range8 = iMat(s,:);
                    range8(range8==0) = [];
                    range8 = (range8(1)-1)*8+1:range8(end)*8;
                    tracksCoordAmpCG(parentSeg, range8) = tracksCoordAmpCG(s, range8);
                    
                    rmIdx = [rmIdx s]; %#ok<AGROW>
                end % segment loop
            end
            rmIdx = unique(rmIdx);
            tracksFeatIndxCG(rmIdx,:) = [];
            tracksCoordAmpCG(rmIdx,:) = [];
            
            % re-order seqOfEvents
            [~,ridx] = sort(seqOfEvents(:,1));
            %[~,lidx] = sort(ridx);
            seqOfEvents = seqOfEvents(ridx,:);
            
            % indexes in seqOfEvents must be in order of segment appearance
            % replace with unique(seqOfEvents(:,3), 'stable') in future versions (>= 2012a)
            oldIdx = seqOfEvents(:,3);
            [~, m] = unique(oldIdx, 'first');
            % mapping: oldIdx(sort(m)) -> 1:nSeg
            idxMap = oldIdx(sort(m));
            [~,newIdx] = ismember(oldIdx, idxMap);
            seqOfEvents(:,3) = newIdx;
            % replace parent indexes
            [~,newIdx] = ismember(seqOfEvents(:,4), idxMap);
            seqOfEvents(:,4) = newIdx;
            seqOfEvents(seqOfEvents(:,4)==0,4) = NaN;
            
            % re-assign to trackinfo, re-arrange with new index
            [~,ridx] = sort(idxMap);
            [~,lidx] = sort(ridx);
            trackinfo(i).seqOfEvents = seqOfEvents;
            trackinfo(i).tracksCoordAmpCG = tracksCoordAmpCG(lidx,:);
            trackinfo(i).tracksFeatIndxCG = tracksFeatIndxCG(lidx,:);
        end
    end
end % preprocess
%======================================================================


disp('preprocessing done')

%%%%


% Set up track structure
tracks(1:nTracks) = struct('t', [], 'f', [],...
    'x', [], 'y', [], 'z', [], 'A', [], 'c', [],...
    'x_pstd', [], 'y_pstd', [], 'z_pstd', [], 'A_pstd', [], 'c_pstd', [],...
    'sigma_r', [], 'SE_sigma_r', [],...
    'pval_Ar', [], 'isPSF', [],...
    'tracksFeatIndxCG', [], 'gapVect', [], 'gapStatus', [], 'gapIdx', [], 'seqOfEvents', [],...
    'nSeg', [], 'visibility', [], 'lifetime_s', [], 'start', [], 'end', [],...
    'startBuffer', [], 'endBuffer', [], 'MotionAnalysis', []);

% track field names
idx = structfun(@(i) size(i,2)==size(frameInfo(1).x,2), frameInfo(1));
mcFieldNames = fieldnames(frameInfo);
[~,loc] = ismember({'x_init', 'y_init', 'z_init', 'xCoord', 'yCoord', 'zCoord', 'amp', 'dRange'}, mcFieldNames);
idx(loc(loc~=0)) = false;
mcFieldNames = mcFieldNames(idx);
mcFieldSizes = structfun(@(i) size(i,1), frameInfo(find(arrayfun(@(f) ~isempty(f.x), frameInfo), 1, 'first')));
mcFieldSizes = mcFieldSizes(idx);
bufferFieldNames = {'t', 'x', 'y', 'z', 'A', 'c', 'A_pstd', 'c_pstd', 'sigma_r', 'SE_sigma_r', 'pval_Ar'};

%==============================
% Loop through tracks
%==============================
%fprintf('Processing tracks (%s) - converting tracker output:     ', getShortPath(data));

for k = 1:nTracks
    
    % convert/assign structure fields
    seqOfEvents = trackinfo(k).seqOfEvents;
    tracksFeatIndxCG = trackinfo(k).tracksFeatIndxCG; % index of the feature in each frame
    nSeg = size(tracksFeatIndxCG,1);
    
    segLengths = NaN(1,nSeg);
    
    % Remove short merging/splitting branches
    msIdx = NaN(1,nSeg);
    for s = 1:nSeg
        idx = seqOfEvents(:,3)==s;
        ievents = seqOfEvents(idx, :);
        bounds = ievents(:,1); % beginning & end of this segment
        if ~isnan(ievents(2,4))
            bounds(2) = bounds(2)-1; % correction if end is a merge
        end
        segLengths(s) = bounds(2)-bounds(1)+1;
        
        % remove short (<4 frames) merging/splitting branches if:
        % -the segment length is a single frame
        % -the segment is splitting and merging from/to the same parent
        % -short segment merges, segment starts after track start
        % -short segment splits, segment ends before track end
        msIdx(s) = segLengths(s)==1 || (segLengths(s)<4 && ( diff(ievents(:,4))==0 ||...
            (isnan(ievents(1,4)) && ~isnan(ievents(2,4)) && ievents(1,1)>seqOfEvents(1,1)) ||...
            (isnan(ievents(2,4)) && ~isnan(ievents(1,4)) && ievents(2,1)<seqOfEvents(end,1)) ));
    end
    if preprocess && nSeg>1
        segIdx = find(msIdx==0); % index segments to retain (avoids re-indexing segments)
        nSeg = numel(segIdx); % update segment #
        msIdx = find(msIdx);
        if ~isempty(msIdx)
            tracksFeatIndxCG(msIdx,:) = [];
            seqOfEvents(ismember(seqOfEvents(:,3), msIdx),:) = [];
        end
        segLengths = segLengths(segIdx);
    else
        segIdx = 1:nSeg;
    end
    
    tracks(k).nSeg = nSeg;
    firstIdx = trackinfo(k).seqOfEvents(1,1);
    lastIdx = trackinfo(k).seqOfEvents(end,1);
    
    tracks(k).lifetime_s = (lastIdx-firstIdx+1)*framerate_s;
    tracks(k).start = firstIdx;
    tracks(k).end = lastIdx;
    
    tracks(k).seqOfEvents = seqOfEvents;
    tracks(k).tracksFeatIndxCG = tracksFeatIndxCG; % index of the feature in each frame
    
    if (buffer(1)<tracks(k).start) && (tracks(k).end<=nFrames-buffer(2)) % complete tracks
        tracks(k).visibility = 1;
    elseif tracks(k).start==1 && tracks(k).end==nFrames % persistent tracks
        tracks(k).visibility = 3;
    else
        tracks(k).visibility = 2; % incomplete tracks
    end
    
    %==============================================================================
    % Initialize arrays
    %==============================================================================
    
    % Segments are concatenated into single arrays, separated by NaNs.
    fieldLength = sum(segLengths)+nSeg-1;
    for f = 1:length(mcFieldNames)
        tracks(k).(mcFieldNames{f}) = NaN(mcFieldSizes(f), fieldLength);
    end
    tracks(k).t = NaN(1, fieldLength);
    tracks(k).f = NaN(1, fieldLength);
    
    if fieldLength>1
        
        % start buffer size for this track
        sb = firstIdx - max(1, firstIdx-buffer(1));
        eb = min(lastIdx+buffer(2), movieLength)-lastIdx;
        
        if sb>0 && (tracks(k).visibility==1 || BufferAll)
            for f = 1:length(bufferFieldNames)
                tracks(k).startBuffer.(bufferFieldNames{f}) = NaN(nCh, sb);
            end
        end
        if eb>0 && (tracks(k).visibility==1 || BufferAll)
            for f = 1:length(bufferFieldNames)
                tracks(k).endBuffer.(bufferFieldNames{f}) = NaN(nCh, eb);
            end
        end
    end
    
    %==============================================================================
    % Read amplitude & background from detectionResults.mat (localization results)
    %==============================================================================
    delta = [0 cumsum(segLengths(1:end-1))+(1:nSeg-1)];
    
    for s = 1:nSeg
        ievents = seqOfEvents(seqOfEvents(:,3)==segIdx(s), :);
        bounds = ievents(:,1);
        if ~isnan(ievents(2,4))
            bounds(2) = bounds(2)-1;
        end
        
        nf = bounds(2)-bounds(1)+1;
        frameRange = frameIdx(bounds(1):bounds(2)); % relative to movie (also when movie is subsampled)
        
        for i = 1:length(frameRange)
            idx = tracksFeatIndxCG(s, frameRange(i) - tracks(k).start + 1); % -> relative to IndxCG
            if idx ~= 0 % if not a gap, get detection values
                for f = 1:length(mcFieldNames)
                    tracks(k).(mcFieldNames{f})(:,i+delta(s)) = frameInfo(frameRange(i)).(mcFieldNames{f})(:,idx);
                end
            end
        end
        tracks(k).t(delta(s)+(1:nf)) = (bounds(1)-1:bounds(2)-1)*framerate_s;
        tracks(k).f(delta(s)+(1:nf)) = frameRange;
    end
    
    fprintf('\b\b\b\b%3d%%', round(100*k/nTracks));
end
fprintf('\n');

% remove tracks that fall into image boundary
minx = round(arrayfun(@(t) min(t.x(:)), tracks));
maxx = round(arrayfun(@(t) max(t.x(:)), tracks));
miny = round(arrayfun(@(t) min(t.y(:)), tracks));
maxy = round(arrayfun(@(t) max(t.y(:)), tracks));
minz = round(arrayfun(@(t) min(t.z(:)), tracks));
maxz = round(arrayfun(@(t) max(t.z(:)), tracks));


filenames = getAllFiles(inputParametersMap('inputDataFolder'));
tifFilenames = contains(filenames,".tif");
filenames = filenames(tifFilenames);
uniqueFilenameString = inputParametersMap('ch1_uniqueFilenameString');
wantedFilenames = contains(filenames,uniqueFilenameString);
filenames = sort(filenames(wantedFilenames));
path = char(filenames(1));

info = imfinfo(path);
nz = numel(info);
nx = info(1).Width;
ny = info(1).Height;

idx = minx<=w4x | miny<=w4x | maxx>nx-w4x | maxy>ny-w4x | maxz>nz-w4x | minz<=w4x;
tracks(idx) = [];
nTracks = numel(tracks);

%=======================================
% Interpolate gaps and clean up tracks
%=======================================
%fprintf('Processing tracks (%s) - classification:     ', getShortPath(data));
disp('Processing tracks - classification:     ')
for k = 1:nTracks
    
    % gap locations in 'x' for all segments
    gapVect = isnan(tracks(k).x(1,:)) & ~isnan(tracks(k).t);
    tracks(k).gapVect = gapVect;
    
    %=================================
    % Determine track and gap status
    %=================================
    sepIdx = isnan(tracks(k).t);
    
    gapCombIdx = diff(gapVect | sepIdx);
    gapStarts = find(gapCombIdx==1)+1;
    gapEnds = find(gapCombIdx==-1);
    gapLengths = gapEnds-gapStarts+1;
    
    segmentIdx = diff([0 ~(gapVect | sepIdx) 0]); % these variables refer to segments between gaps
    segmentStarts = find(segmentIdx==1);
    segmentEnds = find(segmentIdx==-1)-1;
    segmentLengths = segmentEnds-segmentStarts+1;
    
    % loop over gaps
    nGaps = numel(gapLengths);
    if nGaps>0
        gv = 1:nGaps;
        gapStatus = 5*ones(1,nGaps);
        % gap valid if segments that precede/follow are > 1 frame or if gap is a single frame
        gapStatus(segmentLengths(gv)>1 & segmentLengths(gv+1)>1 | gapLengths(gv)==1) = 4;
        
        sepIdx = sepIdx(gapStarts)==1;
        gapStatus(sepIdx) = [];
        gapStarts(sepIdx) = [];
        gapEnds(sepIdx) = [];
        nGaps = numel(gapStatus);
        
        % fill position information for valid gaps using linear interpolation
        for g = 1:nGaps
            borderIdx = [gapStarts(g)-1 gapEnds(g)+1];
            gacombIdx = gapStarts(g):gapEnds(g);
            for c = 1:nCh
                tracks(k).x(c, gacombIdx) = interp1(borderIdx, tracks(k).x(c, borderIdx), gacombIdx);
                tracks(k).y(c, gacombIdx) = interp1(borderIdx, tracks(k).y(c, borderIdx), gacombIdx);
                tracks(k).z(c, gacombIdx) = interp1(borderIdx, tracks(k).z(c, borderIdx), gacombIdx);
            end
        end
        tracks(k).gapStatus = gapStatus;
        tracks(k).gapIdx = arrayfun(@(i) gapStarts(i):gapEnds(i), 1:nGaps, 'unif', 0);
    end
    fprintf('\b\b\b\b%3d%%', round(100*k/nTracks));
end
fprintf('\n');

%====================================================================================
% Generate buffers before and after track, estimate gap values
%====================================================================================
% Gap map for fast indexing
gapMap = zeros(nTracks, movieLength);
for k = 1:nTracks
    gapMap(k, tracks(k).f(tracks(k).gapVect==1)) = 1;
end

% for buffers:
trackStarts = [tracks.start];
trackEnds = [tracks.end];
trackLengths = trackEnds-trackStarts+1;
fullTracks = [tracks.visibility]==1 | (BufferAll & [tracks.visibility]==2);

fmt = ['%.' num2str(ceil(log10(movieLength+1))) 'd'];
%fprintf('Processing tracks (%s) - gap interpolation, buffer readout:     ', getShortPath(data));
disp('Processing tracks - gap interpolation, buffer readout:     ')

% joh: I dont have the gaussian amplitude function...

for f = 1:movieLength
    
    maskPath = [resultsPath filesep 'dmask_' num2str(f, fmt) '.tif'];
    %maskPath = [resultsPath 'Masks' filesep 'dmask_' num2str(f, fmt) '.tif'];

    mask = readtiff(maskPath);
    % binarize
    mask(mask~=0) = 1;
    labels = double(labelmatrix(bwconncomp(mask)));
    
    for ch = 1:nCh
        %frame = double(readtiff(data.framePathsDS{ch}{f}));
        path = char(filenames(f));
        frame = double(readtiff(path));
        % Joh: I dont have this function
        % Joh: I think this function estimates the amplitude in every pixel that
        % Joh: is covered by the mask and stores them in an array.
        %[A_est, c_est] = estGaussianAmplitude3D(frame, sigmaV(ch,:), 'WindowSize', WindowSize)        
        %disp('sigmaV')
        %disp(sigmaV(ch,:))
        
        %[A_est, c_est] = estGaussianAmplitude3D(frame, sigmaV(ch,:));        
        
        

        %------------------------
        % Gaps
        %------------------------
        % tracks with valid gaps visible in current frame
        currentGapsIdx = find(gapMap(:,f));
        for ki = 1:numel(currentGapsIdx)
            k = currentGapsIdx(ki);
            
            % index in the track structure (.x etc)
            idxList = find(tracks(k).f==f & tracks(k).gapVect==1);
            
            for l = 1:numel(idxList)
                idx = idxList(l);
                xi = roundConstr(tracks(k).x(ch,idx),nx);
                yi = roundConstr(tracks(k).y(ch,idx),ny);
                zi = roundConstr(tracks(k).z(ch,idx),nz);
                %[t0] = interpTrack(tracks(k).x(ch,idx), tracks(k).y(ch,idx), tracks(k).z(ch,idx), frame, labels, sigmaV(ch,:), A_est(yi,xi,zi), c_est(yi,xi,zi), kLevel);
                [t0] = interpTrack(tracks(k).x(ch,idx), tracks(k).y(ch,idx), tracks(k).z(ch,idx), frame, labels, sigmaV(ch,:), frame(xi,yi,zi), 0.0, kLevel);
                tracks(k) = mergeStructs(tracks(k), ch, idx, t0);
            end
        end
        
        %------------------------
        % start buffer
        %------------------------
        % tracks with start buffers in this frame
        cand = max(1, trackStarts-buffer(1))<=f & f<trackStarts & trackLengths>2;
        % corresponding tracks, only if status = 1
        currentBufferIdx = find(cand & fullTracks);
        
        for ki = 1:length(currentBufferIdx)
            k = currentBufferIdx(ki);
            xi = roundConstr(tracks(k).x(ch,1),nx);
            yi = roundConstr(tracks(k).y(ch,1),ny);
            zi = roundConstr(tracks(k).z(ch,1),nz);
            %[t0] = interpTrack(tracks(k).x(ch,1), tracks(k).y(ch,1), tracks(k).z(ch,1), frame, labels, sigmaV(ch,:), A_est(yi,xi,zi), c_est(yi,xi,zi), kLevel);
            [t0] = interpTrack(tracks(k).x(ch,1), tracks(k).y(ch,1), tracks(k).z(ch,1), frame, labels, sigmaV(ch,:), frame(xi,yi,zi), 0.0, kLevel);
            bi = f - max(1, tracks(k).start-buffer(1)) + 1;
            tracks(k).startBuffer = mergeStructs(tracks(k).startBuffer, ch, bi, t0);
        end
        
        %------------------------
        % end buffer
        %------------------------
        % segments with end buffers in this frame
        cand = trackEnds<f & f<=min(movieLength, trackEnds+buffer(2)) & trackLengths>2;
        % corresponding tracks
        currentBufferIdx = find(cand & fullTracks);
        
        for ki = 1:length(currentBufferIdx)
            k = currentBufferIdx(ki);
            xi = roundConstr(tracks(k).x(ch,end),nx);
            yi = roundConstr(tracks(k).y(ch,end),ny);
            zi = roundConstr(tracks(k).z(ch,end),nz);
            %[t0] = interpTrack(tracks(k).x(ch,end), tracks(k).y(ch,end), tracks(k).z(ch,end), frame, labels, sigmaV(ch,:), A_est(yi,xi,zi), c_est(yi,xi,zi), kLevel);
            [t0] = interpTrack(tracks(k).x(ch,end), tracks(k).y(ch,end), tracks(k).z(ch,end), frame, labels, sigmaV(ch,:), frame(xi,yi,zi), 0.0, kLevel);
            bi = f - tracks(k).end;
            tracks(k).endBuffer = mergeStructs(tracks(k).endBuffer, ch, bi, t0);
        end
        fprintf('\b\b\b\b%3d%%', round(100*(ch + (f-1)*nCh)/(nCh*movieLength)));
    end
end
fprintf('\n');

%--------------------------------------------------------------
% Reverse z-coordinate (to bottom->top of frame ordering)
% and add time vectors to buffers
%--------------------------------------------------------------
for k = 1:nTracks
    tracks(k).z = nz+1-tracks(k).z;
    
    % add buffer time vectors
    if ~isempty(tracks(k).startBuffer)
        b = size(tracks(k).startBuffer.x,2);
        tracks(k).startBuffer.t = ((-b:-1) + tracks(k).start-1) * framerate_s;
        tracks(k).startBuffer.z = nz+1-tracks(k).startBuffer.z;
    end
    if ~isempty(tracks(k).endBuffer)
        b = size(tracks(k).endBuffer.x,2);
        tracks(k).endBuffer.t = (tracks(k).end + (1:b)-1) * framerate_s;
        tracks(k).endBuffer.z = nz+1-tracks(k).endBuffer.z;
    end
end

% load('trackProc.mat');

% sort tracks by decreasing lifetime
[~, sortIdx] = sort([tracks.lifetime_s], 'descend');
tracks = tracks(sortIdx);
    
%============================================================================
% Run post-processing
%============================================================================
if postprocess
    %----------------------------------------------------------------------------
    % I. Assign category to each track
    %----------------------------------------------------------------------------
    % Categories:
    % Ia)  Single tracks with valid gaps
    % Ib)  Single tracks with invalid gaps
    % Ic)  Single tracks cut at beginning or end
    % Id)  Single tracks, persistent
    % IIa) Compound tracks with valid gaps
    % IIb) Compound tracks with invalid gaps
    % IIc) Compound tracks cut at beginning or end
    % IId) Compound tracks, persistent
    
    % The categories correspond to index 1-8, in the above order
    
    validGaps = arrayfun(@(t) max([t.gapStatus 4]), tracks)==4;
    singleIdx = [tracks.nSeg]==1;
    vis = [tracks.visibility];
    
    mask_Ia = singleIdx & validGaps & vis==1;
    mask_Ib = singleIdx & ~validGaps & vis==1;
    idx_Ia = find(mask_Ia);
    idx_Ib = find(mask_Ib);
    trackLengths = [tracks.end]-[tracks.start]+1;
    
    C = [mask_Ia;
        2*mask_Ib;
        3*(singleIdx & vis==2);
        4*(singleIdx & vis==3);
        5*(~singleIdx & validGaps & vis==1);
        6*(~singleIdx & ~validGaps & vis==1);
        7*(~singleIdx & vis==2);
        8*(~singleIdx & vis==3)];
    
    % assign category
    C = num2cell(sum(C,1));
    [tracks.catIdx] = C{:};
    
    
    %----------------------------------------------------------------------------
    % II. Apply filter on buffer intensities
    %----------------------------------------------------------------------------
    % Conditions:
    % - the amplitudes of the 2 frames bordering the signal (in buffers) must be N.S.
    % - the amplitude in at least 2 consecutive frames must be within background in each buffer
    % - the maximum buffer amplitude must be smaller than the maximum track amplitude

    Tbuffer = 2;
    
    % loop through fully observed single tracks (visibility 1)
    idxBuffer = find([tracks.visibility]==1 & [tracks.catIdx]<3);
    hasValidBuffers = false(1, numel(tracks));
    hasValidBuffers(idxBuffer) = 1;
    for k = 1:numel(idxBuffer)
        i = idxBuffer(k);
        
        % H0: A = background (p-value >= 0.05)
        % reject validity if: -less than Tbuffer non-significant frames
        %                     -last start buffer & first end buffer frames are significant
        %                     -max intensity of buffers is higher than max intensity of signal
        sbin = tracks(i).startBuffer.pval_Ar(1,:) < 0.05; % positions with signif. signal
        ebin = tracks(i).endBuffer.pval_Ar(1,:) < 0.05;
%%%        [sl, sv] = binarySegmentLengths(sbin); % returns [lengths, value]
%%%        [el, ev] = binarySegmentLengths(ebin);
%%%        if ~any(sl(sv==0)>=Tbuffer) || ~any(el(ev==0)>=Tbuffer) ||...
%%%                ~(sbin(end)==0 && ebin(1)==0) ||...
%%%                max([tracks(i).startBuffer.A(1,:)+tracks(i).startBuffer.c(1,:)...
%%%                tracks(i).endBuffer.A(1,:)+tracks(i).endBuffer.c(1,:)]) >...
%%%                max(tracks(i).A(1,:)+tracks(i).c(1,:))
%%%            
%%%            hasValidBuffers(i) = 0;
%%%        end
    end
    
    %----------------------------------------------------------------------------
    % III. identify 'hotspot' tracks with sawtooth intensity profiles
    %----------------------------------------------------------------------------
    isHotspot = false(1, numel(tracks));
    for k = find([tracks.lifetime_s]>30 & [tracks.catIdx]<=2)
        % autocorrelation
        ac = conv(tracks(k).A(1,:), tracks(k).A(1,end:-1:1));
        ac = ac(numel(tracks(k).t):end);
        lm = locmax1d(ac, 7);
        % secondary maxima (one-sided)
        if numel(lm)>0
            isHotspot(k) = true;
        end
    end
    isHotspot = num2cell(isHotspot);
    [tracks.hasMultiplePeaks] = isHotspot{:};
    
    
    
    % Valid gaps (i.e., non-significant amplitudes), includes no gaps
    hasValidGaps = false(1, numel(tracks));
    for k = 1:numel(tracks)
        if all(tracks(k).pval_Ar(tracks(k).gapVect) > 0.05)
            hasValidGaps(k) = 1;
        end
    end
    
    
    % distribution of maximum amplitudes of gap-free, valid tracks
    hasGaps = ~arrayfun(@(i) isempty(i.gapIdx), tracks);
    noGapIndex = find(~hasGaps & hasValidBuffers & ~[tracks.hasMultiplePeaks]);    
    AMat = zeros(numel(noGapIndex), movieLength);
    refLengths = zeros(numel(noGapIndex),1);
    for i = 1:numel(noGapIndex)
        refLengths(i) = numel(tracks(noGapIndex(i)).t);
        AMat(i,1:refLengths(i)) = tracks(noGapIndex(i)).A(1,:);       
    end
    % directly average tracks of same duration
    %AMatAvg = zeros(movieLength, movieLength);
    %for i = 1:movieLength
    %    AMatAvg(i,1:movieLength) = mean(AMat(refLengths==i,:),1);
    %end
    
    
    % in 20 second window, calculate 90% CI bounds for max intensity of reference tracks
    ci90 = NaN(movieLength,2);
    w = ceil(20/framerate_s);
    if mod(w,2)==0
        w = w+1;
    end
    b = (w-1)/2;
    maxA = max(AMat,[],2);
    for k = 1:movieLength
        idx = ismember(refLengths, max(k-b,1):min(k+b,movieLength));
        ci90(k,:) = prctile(maxA(idx), [5 95]);
    end
    lv = (0:movieLength-1)*framerate_s;
    idx = ~isnan(ci90(:,1));
    ci90(:,1) = interpln(lv(idx), ci90(idx,1), lv);
    ci90(:,2) = interpln(lv(idx), ci90(idx,2), lv);
    %figure; plot([tracks(noGapIndex).lifetime_s], max(AMat,[],2), 'k.'); 
    %hold on; plot(lv, ci90);
   
    % 'rescue' tracks with gaps based on max. intensity of reference distribution
    idx = find(hasGaps & hasValidGaps & hasValidBuffers);
    validC2 = false(1,numel(tracks));
    for k = 1:numel(idx)
        if max(tracks(idx(k)).A(1,:)) >= ci90(trackLengths(idx(k)),1)
            validC2(idx(k)) = true;
        end
    end
    
    
    % eliminate tracks with >0.33 proportion of gaps overall
    nGaps = arrayfun(@(i) sum(i.gapVect), tracks);
    %rmIdx = nGaps ./ trackLengths > 0.33;
    rmIdx = nGaps ./ trackLengths >= 0.5; % compare effect on lifetimes
    
    
    % eliminate tracks with >= 4 gaps in 7 frame window
    rmIdx2 = false(1,numel(tracks));
    for k = 1:numel(tracks)
        if ~isempty(tracks(k).gapIdx) && trackLengths(k)>=7 &&...
                max(conv(double(tracks(k).gapVect), ones(1,7), 'valid'))>=4
            rmIdx2(k) = true;
        end
    end

    % accepted tracks:
    %  -valid buffers, no gaps
    %  -valid buffers, max intensity within gap-less distribution
    
    cat1 = ((hasValidBuffers & ~hasGaps) | validC2) & ~[tracks.hasMultiplePeaks] & ~rmIdx & ~rmIdx2;
    cat2 = ~cat1 & [tracks.catIdx]<3;
    
    [tracks(cat1).catIdx] = deal(1);
    [tracks(cat2).catIdx] = deal(2);
    
    
%     %----------------------------------------------------------------------------
%     % III. Process 'Ib' tracks:
%     %----------------------------------------------------------------------------
%     % Reference distribution: class Ia tracks
%     % Determine critical max. intensity values from class Ia tracks, per lifetime cohort
%     
%     % # cohorts
%     nc = 5;
%     cohortBounds = prctile([tracks.lifetime_s], linspace(0, 100, nc+1));
%     
%     % calculate max. intensity distribution of reference tracks (valid buffers, no
%     % gaps); test whether distributionof 'Ib' tracks falls within reference
%     
%     % max intensities of all 'Ia' tracks
%     maxInt = arrayfun(@(i) max(i.A(1,:)), tracks(idx_Ia));
%     maxIntDistr = cell(1,nc);
%     mappingThresholdMaxInt = zeros(1,nc);
%     lft_Ia = [tracks(idx_Ia).lifetime_s];
%     for i = 1:nc
%         maxIntDistr{i} = maxInt(cohortBounds(i)<=lft_Ia & lft_Ia<cohortBounds(i+1));
%         % critical values for test
%         mappingThresholdMaxInt(i) = prctile(maxIntDistr{i}, 2.5);
%     end
%     
%     % get lifetime histograms before change
%     processingInfo.lftHists.before = getLifetimeHistogram(data, tracks);
%     
%     % Criteria for mapping:
%     % - max intensity must be within 2.5th percentile of max. intensity distribution for 'Ia' tracks
%     % - lifetime >= 5 frames (at 4 frames: track = [x o o x])
%     
%     % assign category I to tracks that match criteria
%     for k = 1:numel(idx_Ib);
%         i = idx_Ib(k);
%         
%         % get cohort idx for this track (logical)
%         cIdx = cohortBounds(1:nc)<=tracks(i).lifetime_s & tracks(i).lifetime_s<cohortBounds(2:nc+1);
%         
%         if max(tracks(i).A(mCh,:)) >= mappingThresholdMaxInt(cIdx) && trackLengths(i)>4
%             tracks(i).catIdx = 1;
%         end
%     end
%     processingInfo.lftHists.after = getLifetimeHistogram(data, tracks);
    
    

%     %----------------------------------------------------------------------------
%     % VI. Cut tracks with sequential events (hotspots) into individual tracks
%     %----------------------------------------------------------------------------
%     splitCand = find([tracks.catIdx]==1 & arrayfun(@(i) ~isempty(i.gapIdx), tracks) & trackLengths>4);
%     
%     % Loop through tracks and test whether gaps are at background intensity
%     rmIdx = []; % tracks to remove from list after splitting
%     newTracks = [];
%     for i = 1:numel(splitCand);
%         k = splitCand(i);
%         
%         % all gaps
%         gapIdx = [tracks(k).gapIdx{:}];
%         
%         % # residual points
%         npx = round((tracks(k).sigma_r(mCh,:) ./ tracks(k).SE_sigma_r(mCh,:)).^2/2+1);
%         npx = npx(gapIdx);
%         
%         % t-test on gap amplitude
%         A = tracks(k).A(mCh, gapIdx);
%         sigma_A = tracks(k).A_pstd(mCh, gapIdx);
%         T = (A-sigma_A)./(sigma_A./sqrt(npx));
%         pval = tcdf(T, npx-1);
%         
%         % gaps with signal below background level: candidates for splitting
%         splitIdx = pval<0.05;
%         gapIdx = gapIdx(splitIdx==1);
%         
%         % new segments must be at least 5 frames
%         delta = diff([1 gapIdx trackLengths(k)]);
%         gapIdx(delta(1:end-1)<5 | delta(2:end)<5) = [];
%         
%         ng = numel(gapIdx);
%         splitIdx = zeros(1,ng);
%         
%         for g = 1:ng
%             
%             % split track at gap position
%             x1 = tracks(k).x(mCh, 1:gapIdx(g)-1);
%             y1 = tracks(k).y(mCh, 1:gapIdx(g)-1);
%             x2 = tracks(k).x(mCh, gapIdx(g)+1:end);
%             y2 = tracks(k).y(mCh, gapIdx(g)+1:end);
%             mux1 = median(x1);
%             muy1 = median(y1);
%             mux2 = median(x2);
%             muy2 = median(y2);
%             
%             % projections
%             v = [mux2-mux1; muy2-muy1];
%             v = v/norm(v);
%             
%             % x1 in mux1 reference
%             X1 = [x1-mux1; y1-muy1];
%             sp1 = sum(repmat(v, [1 numel(x1)]).*X1,1);
%             
%             % x2 in mux1 reference
%             X2 = [x2-mux1; y2-muy1];
%             sp2 = sum(repmat(v, [1 numel(x2)]).*X2,1);
%             
%             % test whether projections are distinct distributions of points
%             % may need to be replaced by outlier-robust version
%             if mean(sp1)<mean(sp2) && prctile(sp1,95)<prctile(sp2,5)
%                 splitIdx(g) = 1;
%             elseif mean(sp1)>mean(sp2) && prctile(sp1,5)>prctile(sp2,95)
%                 splitIdx(g) = 1;
%             else
%                 splitIdx(g) = 0;
%             end
%         end
%         gapIdx = gapIdx(splitIdx==1);
%         
%         if ~isempty(gapIdx)
%             % store index of parent track, to be removed at end
%             rmIdx = [rmIdx k]; %#ok<AGROW>
%             
%             % new tracks
%             splitTracks = cutTrack(tracks(k), gapIdx);
%             newTracks = [newTracks splitTracks]; %#ok<AGROW>
%         end
%     end
%     % final assignment
%     % fprintf('# tracks cut: %d\n', numel(rmIdx));
%     tracks(rmIdx) = [];
%     tracks = [tracks newTracks];
%     
%     % remove tracks with more gaps than frames
%     nGaps = arrayfun(@(i) sum(i.gapVect), tracks);
%     trackLengths = [tracks.end]-[tracks.start]+1;
%     
%     % fprintf('# tracks with >50%% gaps: %d\n', sum(nGaps./trackLengths>=0.5));
%     [tracks(nGaps./trackLengths>=0.5).catIdx] = deal(2);
    
    
    % Displacement statistics: remove tracks with >4 large frame-to-frame displacements
    nt = numel(tracks);
    dists = cell(1,nt);
    medianDist = zeros(1,nt);
    for i = 1:nt
        dists{i} = sqrt((tracks(i).x(1,2:end) - tracks(i).x(1,1:end-1)).^2 +...
            (tracks(i).y(1,2:end) - tracks(i).y(1,1:end-1)).^2 +...
            (tracks(i).z(1,2:end) - tracks(i).z(1,1:end-1)).^2);
        medianDist(i) = nanmedian(dists{i});
    end
    p95 = prctile(medianDist, 95);
    for i = 1:nt
        if sum(dists{i}>p95)>4 && tracks(i).catIdx==1
            tracks(i).catIdx = 2;
        end
    end
    
    
    %==========================================
    % Compute displacement statistics
    %==========================================
    % Only on valid tracks (Cat. Ia)
    trackIdx = find([tracks.catIdx]<5);
    %fprintf('Processing tracks (%s) - calculating statistics:     ', getShortPath(data));
    disp('Processing tracks - calculating statistics:     ');
    for ki = 1:numel(trackIdx)
        k = trackIdx(ki);
        x = tracks(k).x(1,:);
        y = tracks(k).y(1,:);
        z = tracks(k).z(1,:);
        tracks(k).MotionAnalysis.totalDisplacement = sqrt((x(end)-x(1))^2 + (y(end)-y(1))^2 + (z(end)-z(1))^2);
        % calculate MSD
        L = 10;
        msdVect = NaN(1,L);
        msdStdVect = NaN(1,L);
        for l = 1:min(L, numel(x)-1)
            tmp = (x(1+l:end)-x(1:end-l)).^2 + (y(1+l:end)-y(1:end-l)).^2 + (z(1+l:end)-z(1:end-l)).^2;
            msdVect(l) = mean(tmp);
            msdStdVect(l) = std(tmp);
        end
        tracks(k).MotionAnalysis.MSD = msdVect;
        tracks(k).MotionAnalysis.MSDstd = msdStdVect;
        fprintf('\b\b\b\b%3d%%', round(100*ki/numel(trackIdx)));
    end
    fprintf('\n');
    
    fprintf('Processing complete - valid/total tracks: %d/%d (%.1f%%).\n',...
       sum([tracks.catIdx]==1), numel(tracks), sum([tracks.catIdx]==1)/numel(tracks)*100);
    
end % postprocessing

%=================================================================================
% Classify slave channel signals
%=================================================================================
% bg95 = prctile([bgA{:}], 95, 2);


if nCh > 1
    for k = 1:numel(tracks)
        np = numel(tracks(k).t); % # points/track
        %tracks(k).isDetected = true(nCh, np);
        tracks(k).significantMaster = true(nCh,1);
        tracks(k).significantVsBackground = true(nCh,np);
        tracks(k).significantSlave = false(nCh,1); % NaN !

        for c = setdiff(1:nCh,1); % loop through all slave channels
            %tracks(k).significantMaster(c) = nansum(tracks(k).isDetected(c,:)) > binoinv(0.95, np, pSlave(c));
            tracks(k).significantMaster(c) = nansum(tracks(k).hval_Ar(c,:)) > 1;
        end
    end
end




%==========================================
% Save results
%==========================================
%%% if ~(exist([data.source 'Analysis'], 'dir')==7)
%%%     mkdir([data.source 'Analysis']);
%%% end
%%% if isunix
%%%     cmd = ['svn info ' mfilename('fullpath') '.m | grep "Last Changed Rev"'];
%%%    [status,rev] = system(cmd);
%%%    if status==0
%%%        rev = regexp(rev, '\d+', 'match');
%%%        processingInfo.revision = rev{1};
%%%    end
%%% end
%%% processingInfo.procFlag = [preprocess postprocess];
%%%
%%% save([resultsPath opts.FileName], 'tracks', 'processingInfo');
%%% end
trackingFilenameProcessed = inputParametersMap('ch1_trackingFilenameProcessed');
save([resultsPath '/' trackingFilenameProcessed ], 'tracks');

disp([resultsPath '/' trackingFilenameProcessed ])
disp('IV_onlyTrackingProcessing(): done.')
end

% calculate track fields for gap or buffer position
function [ps] = interpTrack(x, y, z, frame, labels, sigma, ai, ci, kLevel)

w1x = ceil(sigma(1)); % changed from 2*sigma, test!
w2x = ceil(2*sigma(1));
%w1z = ceil(sigma(2)); joh, this was here before.
%w2z = ceil(2*sigma(2)); joh, this was here before.
w1z = ceil(sigma(1));
w2z = ceil(2*sigma(1));

[ny,nx,nz] = size(frame);
xi = roundConstr(x,nx);
yi = roundConstr(y,ny);
zi = roundConstr(z,nz);

% window boundaries
xa = max(1,xi-w2x):min(nx,xi+w2x);
ya = max(1,yi-w2x):min(ny,yi+w2x);
za = max(1,zi-w2z):min(nz,zi+w2z);

% relative coordinates of (xi, yi, zi) in window. Origin at (0,0,0)
ox = xi-xa(1);
oy = yi-ya(1);
oz = zi-za(1);

% label mask
maskWindow = labels(ya, xa, za);
maskWindow(maskWindow==maskWindow(oy+1,ox+1,oz+1)) = 0;

window = frame(ya, xa, za);
window(maskWindow~=0) = NaN;
npx = sum(isfinite(window(:)));
    
% if npx >= 20 % only perform fit if window contains sufficient data points

[prm, prmStd, ~, res] = fitGaussian3D(window, [x-xi+ox y-yi+oy z-zi+oz ai sigma ci], 'xyzAc');
dx = prm(1)-ox;
dy = prm(2)-oy;
dz = prm(3)-oz;

if (dx > -w1x && dx < w1x && dy > -w1x && dy < w1x && dz > -w1z && dz < w1z)
    ps.x = xi+dx;
    ps.y = yi+dy;
    ps.z = zi+dz;
    ps.A_pstd = prmStd(4);
    ps.c_pstd = prmStd(5);
else
    [prm, prmStd, ~, res] = fitGaussian3D(window, [x-xi+ox y-yi+oy z-zi+oz ai sigma ci], 'Ac');
    ps.x = x;
    ps.y = y;
    ps.z = z;
    ps.A_pstd = prmStd(1);
    ps.c_pstd = prmStd(2);
end
ps.A = prm(4);
ps.c = prm(7);

ps.sigma_r = res.std;
ps.SE_sigma_r = res.std/sqrt(2*(npx-1));

SE_r = ps.SE_sigma_r * kLevel;

ps.hval_AD = res.hAD;

df2 = (npx-1) * (ps.A_pstd.^2 + SE_r.^2).^2 ./...
    (ps.A_pstd.^4 + SE_r.^4);

scomb = sqrt((ps.A_pstd.^2 + SE_r.^2)/npx);
T = (ps.A - res.std*kLevel) ./ scomb;
ps.pval_Ar = tcdf(-T, df2);
end


function ps = mergeStructs(ps, ch, idx, cs)

cn = fieldnames(cs);
for f = 1:numel(cn)
    ps.(cn{f})(ch,idx) = cs.(cn{f});
end
end

function y = roundConstr(x, nx)
y = round(x);
y(y<1) = 1;
y(y>nx) = nx;
end