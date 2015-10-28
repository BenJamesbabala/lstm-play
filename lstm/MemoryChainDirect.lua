-- This variant assumes that one wants to do a 1-to-1 sequence labeling task
-- and thus the output will be the hidden states for each timestep.

local stringx = require 'pl.stringx'

local MemoryChainDirect, parent = torch.class('lstm.MemoryChainDirect', 'lstm.MemoryChain')

-- Same as MemoryChain, except direct only supports one layer, because it seems
-- to make more sense to interlace forward and backward layers.
function MemoryChainDirect:__init(inputSize, hiddenSizes, maxLength)
  if #hiddenSizes ~= 1 then
    error("MemoryChainDirect only works with exactly one layer")
  end
  parent.__init(self, inputSize, hiddenSizes, maxLength)
end

-- Receives a table containing two Tensors: input and a vector of lengths, as not all
-- sequences will span the full length dimension of the tensor.
-- If input is 3D then the first dimension is batch, otherwise the first dim
-- is the sequence. Last dimension is features.
-- Output is size BxLxH
function MemoryChainDirect:updateOutput(tuple)
  local input, lengths = unpack(tuple)
  lengths = torch.nonzero(lengths):select(2,2)
  if input:dim() ~= 3 then
    error("expecting a 3D input")
  end
  local batchSize = input:size(1)
  local longestExample = input:size(2)

  -- Storage for output
  local layerSize = self.hiddenSizes[1]
  self.output:resize(batchSize, longestExample, layerSize)

  -- The first memory cell will receive zeros.
  local h = self:makeTensor(torch.LongStorage{batchSize,layerSize})
  local c = self:makeTensor(torch.LongStorage{batchSize,layerSize})

  -- Iterate over memory cells feeding each successive tuple (h,c) into the next
  -- LSTM memory cell.
  for t=1,longestExample do
    local x = input:select(2, t)
    h, c = unpack(self.lstms[1][t]:forward({h, c, x}))
    -- At present we copy all timesteps for all batch members. It's up to the
    -- prediction layer to only use the ones that are relevant for each batch
    -- memeber.
    self.output:select(2,t):copy(h)
  end
  return self.output
end

-- upstreamGradOutput will be a BxLxH matrix where B is batch size L is length
-- and H is hidden state size. It contains the gradient of the objective function
-- wrt outputs from the LSTM memory cell at each position in the sequence.
function MemoryChainDirect:updateGradInput(tuple, upstreamGradOutput)
  local input, lengths = unpack(tuple)
  local batchSize = input:size(1)
  local len = input:size(2)
  self.gradInput[1]:resize(batchSize, len, self.inputSize):zero()
  self.gradInput[2]:resizeAs(lengths):zero()

  lengths = torch.nonzero(lengths):select(2,2)
  local h,c
  if input:dim() ~= 3 then
    error("MemoryChainDirect:updageGradInput is expecting a 3D input tensor")
  end

  -- Because each batch member has a sequence of a different length less than
  -- or equal to len, we need to have some way to propagate errors starting
  -- at the correct level. 

  -- Memory we'll use for the upstream messages of each LSTM memory cell.
  -- Since each memory cell outputs an h and c, we need gradients of these.
  local gradOutput = {
    torch.Tensor():typeAs(self.output),
    torch.Tensor():typeAs(self.output)
  }

  -- Go in reverse order from the highest layer down and from the end back to
  -- the beginning.
  local layerSize = self.hiddenSizes[1]
  gradOutput[1]:resize(batchSize, layerSize)
  gradOutput[2]:resize(batchSize, layerSize)
  for t=len,1,-1 do
    gradOutput[1]:zero()
    gradOutput[2]:zero()
    -- If we're in the top layer, we'll get some messages from upstreamGradOutput,
    -- otherwise we'll get the messages from the lstm above. In either case, above
    -- will be BxH.
    local above = upstreamGradOutput:select(2,t)
    -- Only incorporate messages from above if batch member is at least t long.
    for b=1,batchSize do
      if t <= lengths[b] then
        gradOutput[1][b]:add(above[b])
      end
    end
      
    -- Only get messages from the right if we're not at the right-most edge or
    -- this batch member's sequence doesn't extend right.
    if t < len then
      local lstmRight = self.lstms[1][t+1]
      for b=1,batchSize do
        if t < lengths[b] then
          -- message from h
          gradOutput[1][b]:add(lstmRight.gradInput[1][b])
          -- message from c
          gradOutput[2][b]:add(lstmRight.gradInput[2][b])
        end
      end
    end

    -- Backward propagate this memory cell
    local x = input:select(2,t)
    if t == 1 then
      h = self:makeTensor(torch.LongStorage{batchSize,layerSize})
      c = self:makeTensor(torch.LongStorage{batchSize,layerSize})
    else
      h = self.lstms[1][t-1].output[1]
      c = self.lstms[1][t-1].output[2]
    end
    self.lstms[1][t]:backward({h, c, x}, gradOutput)
    self.gradInput[1]:select(2,t):copy(self.lstms[1][t].gradInput[3])
  end
  return self.gradInput
end

-- END
