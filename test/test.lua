
local rnntest = {}
local precision = 1e-5
local mytester

function rnntest.Recurrent()
   local batchSize = 4
   local dictSize = 100
   local hiddenSize = 12
   local outputSize = 7
   local nSteps = 5 
   local inputModule = nn.Dictionary(dictSize, outputSize)
   local transferModule = nn.Sigmoid()
   -- test MLP feedback Module (because of Module:representations())
   local feedbackModule = nn.Sequential()
   feedbackModule:add(nn.Linear(outputSize, hiddenSize))
   feedbackModule:add(nn.Sigmoid())
   feedbackModule:add(nn.Linear(hiddenSize, outputSize))
   -- rho = nSteps
   local mlp = nn.Recurrent(outputSize, inputModule, feedbackModule, transferModule:clone(), nSteps)
 
   local gradOutputs, outputs = {}, {}
   -- inputs = {inputN, {inputN-1, {inputN-2, ...}}}}}
   local inputs
   local startModule = mlp.startModule:clone()
   inputModule = mlp.inputModule:clone()
   feedbackModule = mlp.feedbackModule:clone()
   
   local mlp6 = mlp:clone()
   mlp6:evaluate()
   
   mlp:zeroGradParameters()
   local mlp7 = mlp:clone()
   mlp7.rho = nSteps - 1
   local inputSequence = {}
   for step=1,nSteps do
      local input = torch.IntTensor(batchSize):random(1,dictSize)
      inputSequence[step] = input
      local gradOutput
      if step ~= nSteps then
         -- for the sake of keeping this unit test simple,
         gradOutput = torch.zeros(batchSize, outputSize)
      else
         -- only the last step will get a gradient from the output
         gradOutput = torch.randn(batchSize, outputSize)
      end
      
      local output = mlp:forward(input)
      mlp:backward(input, gradOutput)
      
      local output6 = mlp6:forward(input)
      mytester:assertTensorEq(output, output6, 0.000001, "evaluation error "..step)
      
      local output7 = mlp7:forward(input)
      mlp7:backward(input, gradOutput)
      mytester:assertTensorEq(output, output7, 0.000001, "rho = nSteps-1 forward error "..step)

      table.insert(gradOutputs, gradOutput)
      table.insert(outputs, output:clone())
      
      if inputs then
         inputs = {input, inputs}
      else
         inputs = input
      end
   end

   local mlp4 = mlp:clone()
   local mlp5 = mlp:clone()
   
   -- backward propagate through time (BPTT)
   local gradInput = mlp:backwardThroughTime():clone()
   mlp:forget() -- test ability to forget
   mlp:zeroGradParameters()
   local foutputs = {}
   for step=1,nSteps do
      foutputs[step] = mlp:forward(inputSequence[step])
      mytester:assertTensorEq(foutputs[step], outputs[step], 0.00001, "Recurrent forget output error "..step)
      mlp:backward(input, gradOutputs[step])
   end
   local fgradInput = mlp:backwardThroughTime():clone()
   mytester:assertTensorEq(gradInput, fgradInput, 0.00001, "Recurrent forget gradInput error")
   
   mlp4.fastBackward = false
   local gradInput4 = mlp4:backwardThroughTime()
   mytester:assertTensorEq(gradInput, gradInput4, 0.000001, 'error slow vs fast backwardThroughTime')
   local mlp10 = mlp7:clone()
   --mytester:assert(mlp10.inputs[1] == nil, 'recycle inputs error')
   mlp10:forget()
   --mytester:assert(#mlp10.inputs == 4, 'forget inputs error')
   mytester:assert(#mlp10.outputs == 5, 'forget outputs error')
   local i = 0
   for k,v in pairs(mlp10.sharedClones) do
      i = i + 1
   end
   mytester:assert(i == 4, 'forget recurrentOutputs error')
   
   -- rho = nSteps - 1 : shouldn't update startModule
   mlp7:backwardThroughTime()
   
   local mlp2 -- this one will simulate rho = nSteps
   local outputModules = {}
   for step=1,nSteps do
      local inputModule_ = inputModule:sharedClone()
      local outputModule = transferModule:clone()
      table.insert(outputModules, outputModule)
      if step == 1 then
         local initialModule = nn.Sequential()
         initialModule:add(inputModule_)
         initialModule:add(startModule)
         initialModule:add(outputModule)
         mlp2 = initialModule
      else
         local parallelModule = nn.ParallelTable()
         parallelModule:add(inputModule_)
         local pastModule = nn.Sequential()
         pastModule:add(mlp2)
         local feedbackModule_ = feedbackModule:sharedClone()
         pastModule:add(feedbackModule_)
         parallelModule:add(pastModule)
         local recurrentModule = nn.Sequential()
         recurrentModule:add(parallelModule)
         recurrentModule:add(nn.CAddTable())
         recurrentModule:add(outputModule)
         mlp2 = recurrentModule
      end
   end
   
   
   local output2 = mlp2:forward(inputs)
   mlp2:zeroGradParameters()
   
   -- unlike mlp2, mlp8 will simulate rho = nSteps -1
   local mlp8 = mlp2:clone() 
   local inputModule8 = mlp8.modules[1].modules[1]
   local m = mlp8.modules[1].modules[2].modules[1].modules[1].modules[2]
   m = m.modules[1].modules[1].modules[2].modules[1].modules[1].modules[2]
   local feedbackModule8 = m.modules[2]
   local startModule8 = m.modules[1].modules[2] -- before clone
   -- unshare the intialModule:
   m.modules[1] = m.modules[1]:clone()
   m.modules[2] = m.modules[2]:clone()
   mlp8:backward(inputs, gradOutputs[#gradOutputs])
   
   local gradInput2 = mlp2:backward(inputs, gradOutputs[#gradOutputs])
   for step=1,nSteps-1 do
      gradInput2 = gradInput2[2]
   end   
   
   mytester:assertTensorEq(gradInput, gradInput2, 0.000001, "recurrent gradInput")
   mytester:assertTensorEq(outputs[#outputs], output2, 0.000001, "recurrent output")
   for step=1,nSteps do
      local output, outputModule = outputs[step], outputModules[step]
      mytester:assertTensorEq(output, outputModule.output, 0.000001, "recurrent output step="..step)
   end
   
   local mlp3 = nn.Sequential()
   -- contains params and grads of mlp2 (the MLP version of the Recurrent)
   mlp3:add(startModule):add(inputModule):add(feedbackModule)
   local params2, gradParams2 = mlp3:parameters()
   local params, gradParams = mlp:parameters()
   
   mytester:assert(#_.keys(params2) == #_.keys(params), 'missing parameters')
   mytester:assert(#_.keys(gradParams) == #_.keys(params), 'missing gradParameters')
   mytester:assert(#_.keys(gradParams2) == #_.keys(params), 'missing gradParameters2')
   
   for i,v in pairs(params) do
      mytester:assertTensorEq(gradParams[i], gradParams2[i], 0.000001, 'gradParameter error ' .. i)
   end
   
   local mlp9 = nn.Sequential()
   -- contains params and grads of mlp8
   mlp9:add(startModule8):add(inputModule8):add(feedbackModule8)
   local params9, gradParams9 = mlp9:parameters()
   local params7, gradParams7 = mlp7:parameters()
   mytester:assert(#_.keys(params9) == #_.keys(params7), 'missing parameters')
   mytester:assert(#_.keys(gradParams7) == #_.keys(params7), 'missing gradParameters')
   for i,v in pairs(params7) do
      mytester:assertTensorEq(gradParams7[i], gradParams9[i], 0.00001, 'gradParameter error ' .. i)
   end
   
   -- already called backwardThroughTime()
   mlp:updateParameters(0.1) 
   mlp4:updateParameters(0.1) 
   
   local params4 = mlp4:sparseParameters()
   local params5 = mlp5:sparseParameters()
   local params = mlp:sparseParameters()
   mytester:assert(#_.keys(params4) == #_.keys(params), 'missing parameters')
   mytester:assert(#_.keys(params5) ~= #_.keys(params), 'missing parameters') -- because of nn.Dictionary (it has sparse params)
   for k,v in pairs(params) do
      mytester:assertTensorEq(params[k], params4[k], 0.000001, 'backwardThroughTime error ' .. i)
      if params5[k] then
         mytester:assertTensorNe(params[k], params5[k], 0.0000000001, 'backwardThroughTime error ' .. i)
      end
   end
   
   -- should call backwardUpdateThroughTime()
   mlp5:updateParameters(0.1)
   
   local params5 = mlp5:parameters()
   local params = mlp:parameters()
   mytester:assert(#_.keys(params5) == #_.keys(params), 'missing parameters')
   for i,v in pairs(params) do
      mytester:assertTensorEq(params[i], params5[i], 0.000001, 'backwardUpdateThroughTime error ' .. i)
   end
   
   mlp:forget()
   mlp:zeroGradParameters()
   local rnn = mlp:float()
   local outputs2 = {}
   for step=1,nSteps do
      rnn:forward(inputSequence[step]:float())
      rnn:backward(inputSequence[step]:float(), gradOutputs[step]:float())
   end
   local gradInput2 = rnn:backwardThroughTime()
end

function rnntest.Recurrent_oneElement()
   -- test sequence of one element
   local x = torch.rand(200)
   local target = torch.rand(2)

   local rho = 5
   local hiddenSize = 100
   -- RNN
   local r = nn.Recurrent(
     hiddenSize, nn.Linear(200,hiddenSize), 
     nn.Linear(hiddenSize, hiddenSize), nn.Sigmoid(), 
     rho
   )

   local seq = nn.Sequential()
   seq:add(r)
   seq:add(nn.Linear(hiddenSize, 2))

   local criterion = nn.MSECriterion()

   local output = seq:forward(x)
   local err = criterion:forward(output,target)
   local gradOutput = criterion:backward(output,target)
   
   seq:backward(x,gradOutput)
   seq:updateParameters(0.01)
end

function rnntest.Recurrent_TestTable()
   -- Set up RNN where internal state is a table.
   -- Trivial example is same RNN from rnntest.Recurrent test
   -- but all layers are duplicated
   local batchSize = 4
   local inputSize = 10
   local hiddenSize = 12
   local outputSize = 7
   local nSteps = 5 
   local inputModule = nn.Linear(inputSize, outputSize)
   local transferModule = nn.Sigmoid()
   local learningRate = 0.1
   -- test MLP feedback Module
   local feedbackModule = nn.Sequential()
   feedbackModule:add(nn.Linear(outputSize, hiddenSize))
   feedbackModule:add(nn.Sigmoid())
   feedbackModule:add(nn.Linear(hiddenSize, outputSize))
   -- rho = nSteps
   local mlp = nn.Recurrent(
      nn.ParallelTable()
         :add(nn.Add(outputSize))
         :add(nn.Add(outputSize)),
      nn.ParallelTable()
         :add(inputModule:clone())
         :add(inputModule:clone()),
      nn.ParallelTable()
         :add(feedbackModule:clone())
         :add(feedbackModule:clone()),
      nn.ParallelTable()
         :add(transferModule:clone())
         :add(transferModule:clone()),
      nSteps,
      nn.ParallelTable()
         :add(nn.CAddTable())
         :add(nn.CAddTable())
   )

   local input = torch.randn(batchSize, inputSize)
   local err = torch.randn(batchSize, outputSize)
   for i=1,10 do
      mlp:forward{input, input:clone()}
      mlp:backward({input, input:clone()}, {err, err:clone()})
   end
   mlp:backwardThroughTime()
end

function rnntest.LSTM()
   local batchSize = math.random(1,2)
   local inputSize = math.random(3,4)
   local outputSize = math.random(5,6)
   local nStep = 3
   local input = {}
   local gradOutput = {}
   for step=1,nStep do
      input[step] = torch.randn(batchSize, inputSize)
      if step == nStep then
         -- for the sake of keeping this unit test simple,
         gradOutput[step] = torch.randn(batchSize, outputSize)
      else
         -- only the last step will get a gradient from the output
         gradOutput[step] = torch.zeros(batchSize, outputSize)
      end
   end
   local lstm = nn.LSTM(inputSize, outputSize)
   
   -- we will use this to build an LSTM step by step (with shared params)
   local lstmStep = lstm.recurrentModule:clone()
   
   -- forward/backward through LSTM
   local output = {}
   lstm:zeroGradParameters()
   for step=1,nStep do
      output[step] = lstm:forward(input[step])
      assert(torch.isTensor(input[step]))
      lstm:backward(input[step], gradOutput[step], 1)
   end   
   local gradInput = lstm:backwardThroughTime()
   
   local mlp2 -- this one will simulate rho = nSteps
   local inputs
   for step=1,nStep do
      -- iteratively build an LSTM out of non-recurrent components
      local lstm = lstmStep:clone()
      lstm:share(lstmStep, 'weight', 'gradWeight', 'bias', 'gradBias')
      if step == 1 then
         mlp2 = lstm
      else
         local rnn = nn.Sequential()
         local para = nn.ParallelTable()
         para:add(nn.Identity()):add(mlp2)
         rnn:add(para)
         rnn:add(nn.FlattenTable())
         rnn:add(lstm)
         mlp2 = rnn
      end
      
      -- prepare inputs for mlp2
      if inputs then
         inputs = {input[step], inputs}
      else
         inputs = {input[step], torch.zeros(batchSize, outputSize), torch.zeros(batchSize, outputSize)}
      end
   end
   mlp2:add(nn.SelectTable(1)) --just output the output (not cell)
   local output2 = mlp2:forward(inputs)
   
   mlp2:zeroGradParameters()
   local gradInput2 = mlp2:backward(inputs, gradOutput[nStep], 1) --/nStep)
   mytester:assertTensorEq(gradInput2[2][2][1], gradInput, 0.00001, "LSTM gradInput error")
   mytester:assertTensorEq(output[nStep], output2, 0.00001, "LSTM output error")
   
   local params, gradParams = lstm:parameters()
   local params2, gradParams2 = lstmStep:parameters()
   mytester:assert(#params == #params2, "LSTM parameters error "..#params.." ~= "..#params2)
   for i, gradParam in ipairs(gradParams) do
      local gradParam2 = gradParams2[i]
      mytester:assertTensorEq(gradParam, gradParam2, 0.000001, 
         "LSTM gradParam "..i.." error "..tostring(gradParam).." "..tostring(gradParam2))
   end
   
   gradParams = lstm.recursiveCopy(nil, gradParams)
   gradInput = gradInput:clone()
   mytester:assert(lstm.zeroTensor:sum() == 0, "zeroTensor error")
   lstm:forget()
   output = lstm.recursiveCopy(nil, output)
   local output3 = {}
   lstm:zeroGradParameters()
   for step=1,nStep do
      output3[step] = lstm:forward(input[step])
      lstm:backward(input[step], gradOutput[step], 1)
   end   
   local gradInput3 = lstm:updateGradInputThroughTime()
   lstm:accGradParametersThroughTime()
   
   mytester:assert(#output == #output3, "LSTM output size error")
   for i,output in ipairs(output) do
      mytester:assertTensorEq(output, output3[i], 0.00001, "LSTM forget (updateOutput) error "..i)
   end
   
   mytester:assertTensorEq(gradInput, gradInput3, 0.00001, "LSTM updateGradInputThroughTime error")
   
   local params3, gradParams3 = lstm:parameters()
   mytester:assert(#params == #params3, "LSTM parameters error "..#params.." ~= "..#params3)
   for i, gradParam in ipairs(gradParams) do
      local gradParam3 = gradParams3[i]
      mytester:assertTensorEq(gradParam, gradParam3, 0.000001, 
         "LSTM gradParam "..i.." error "..tostring(gradParam).." "..tostring(gradParam3))
   end
end

function rnntest.FastLSTM()
   --require 'dp'
   local inputSize = 100
   local batchSize = 40
   local nStep = 3
   
   local input = {}
   local gradOutput = {}
   for step=1,nStep do
      input[step] = torch.randn(batchSize, inputSize)
      gradOutput[step] = torch.randn(batchSize, inputSize)
   end
   local gradOutputClone = gradOutput[1]:clone()
   local lstm1 = nn.LSTM(inputSize, inputSize, nil, false)
   local lstm2 = nn.FastLSTM(inputSize, inputSize, nil)
   local seq1 = nn.Sequencer(lstm1)
   local seq2 = nn.Sequencer(lstm2)
   
   local output1 = seq1:forward(input)
   local gradInput1 = seq1:backward(input, gradOutput)
   mytester:assertTensorEq(gradOutput[1], gradOutputClone, 0.00001, "LSTM modified gradOutput")
   seq1:zeroGradParameters()
   seq2:zeroGradParameters()
   
   -- make them have same params
   local ig = lstm1.inputGate:parameters()
   local hg = lstm1.hiddenLayer:parameters()
   local fg = lstm1.forgetGate:parameters()
   local og = lstm1.outputGate:parameters()
   
   local i2g = lstm2.i2g:parameters()
   local o2g = lstm2.o2g:parameters()
   
   ig[1]:copy(i2g[1]:narrow(1,1,inputSize))
   ig[2]:copy(i2g[2]:narrow(1,1,inputSize))
   ig[3]:copy(o2g[1]:narrow(1,1,inputSize))
   hg[1]:copy(i2g[1]:narrow(1,inputSize+1,inputSize))
   hg[2]:copy(i2g[2]:narrow(1,inputSize+1,inputSize))
   hg[3]:copy(o2g[1]:narrow(1,inputSize+1,inputSize))
   fg[1]:copy(i2g[1]:narrow(1,inputSize*2+1,inputSize))
   fg[2]:copy(i2g[2]:narrow(1,inputSize*2+1,inputSize))
   fg[3]:copy(o2g[1]:narrow(1,inputSize*2+1,inputSize))
   og[1]:copy(i2g[1]:narrow(1,inputSize*3+1,inputSize))
   og[2]:copy(i2g[2]:narrow(1,inputSize*3+1,inputSize))
   og[3]:copy(o2g[1]:narrow(1,inputSize*3+1,inputSize))
   
   local output1 = seq1:forward(input)
   local gradInput1 = seq1:backward(input, gradOutput)
   local output2 = seq2:forward(input)
   local gradInput2 = seq2:backward(input, gradOutput)
   
   mytester:assert(#output1 == #output2 and #output1 == nStep)
   mytester:assert(#gradInput1 == #gradInput2 and #gradInput1 == nStep)
   for i=1,#output1 do
      mytester:assertTensorEq(output1[i], output2[i], 0.000001, "FastLSTM output error "..i)
      mytester:assertTensorEq(gradInput1[i], gradInput2[i], 0.000001, "FastLSTM gradInput error "..i)
   end
end

function rnntest.Sequencer()
   local batchSize = 4
   local inputSize = 3
   local outputSize = 7
   local nSteps = 5 
   
   -- test with recurrent module
   local inputModule = nn.Linear(inputSize, outputSize)
   local transferModule = nn.Sigmoid()
   -- test MLP feedback Module (because of Module:representations())
   local feedbackModule = nn.Euclidean(outputSize, outputSize)
   -- rho = nSteps
   local rnn = nn.Recurrent(outputSize, inputModule, feedbackModule, transferModule, nSteps)
   rnn:zeroGradParameters()
   local rnn2 = rnn:clone()
   
   local inputs, outputs, gradOutputs = {}, {}, {}
   for step=1,nSteps do
      inputs[step] = torch.randn(batchSize, inputSize)
      outputs[step] = rnn:forward(inputs[step]):clone()
      gradOutputs[step] = torch.randn(batchSize, outputSize)
      rnn:backward(inputs[step], gradOutputs[step])
   end
   rnn:backwardThroughTime()
   
   local gradOutput1 = gradOutputs[1]:clone()
   local rnn3 = nn.Sequencer(rnn2)
   local outputs3 = rnn3:forward(inputs)
   mytester:assert(#outputs3 == #outputs, "Sequencer output size err")
   for step,output in ipairs(outputs) do
      mytester:assertTensorEq(outputs3[step], output, 0.00001, "Sequencer output "..step)
   end
   local gradInputs3 = rnn3:backward(inputs, gradOutputs)
  
   mytester:assert(#gradInputs3 == #rnn.gradInputs, "Sequencer gradInputs size err")
   mytester:assert(gradInputs3[1]:nElement() ~= 0) 
   
   for step,output in ipairs(outputs) do
      mytester:assertTensorEq(gradInputs3[step], rnn.gradInputs[step], 0.00001, "Sequencer gradInputs "..step)
   end
   mytester:assertTensorEq(gradOutputs[1], gradOutput1, 0.00001, "Sequencer rnn gradOutput modified error")
   
   local nSteps7 = torch.Tensor{5,4,5,3,7,3,3,3}
   local function testRemember(rnn)
      rnn:zeroGradParameters()
      -- test remember for training mode (with variable length)
      local rnn7 = rnn:clone()
      rnn7:zeroGradParameters()
      local rnn8 = rnn7:clone()
      local rnn9 = rnn7:clone()
      local rnn10 = nn.Recursor(rnn7:clone())
      
      local inputs7, outputs9 = {}, {}
      for step=1,nSteps7:sum() do
         inputs7[step] = torch.randn(batchSize, outputSize)
         outputs9[step] = rnn9:forward(inputs7[step]):clone()
      end
      
      local step = 1
      for i=1,nSteps7:size(1) do
         for j=1,nSteps7[i] do
            mytester:assertTensorEq(outputs9[step], rnn7:forward(inputs7[step]), 0.000001, "Sequencer "..torch.type(rnn7).." remember forward err "..step)
            step = step + 1
         end
      end
      
      rnn7:forget()
      
      local step = 1
      for i=1,nSteps7:size(1) do
         for j=1,nSteps7[i] do
            mytester:assertTensorEq(outputs9[step], rnn7:forward(inputs7[step]), 0.000001, "Sequencer "..torch.type(rnn7).." remember forward2 err "..step)
            step = step + 1
         end
      end
      
      rnn7:forget()
      
      local step = 1
      local outputs7, gradOutputs7, gradInputs7 = {}, {}, {}
      for i=1,nSteps7:size(1) do
         for j=1,nSteps7[i] do
            outputs7[step] = rnn7:forward(inputs7[step]):clone()
            gradOutputs7[step] = torch.randn(batchSize, outputSize)
            rnn7:backward(inputs7[step], gradOutputs7[step])
            step = step + 1
         end
         rnn7:maxBPTTstep(nSteps7[i])
         rnn7.fastBackward = false
         rnn7:backwardThroughTime()
         for i=1,#rnn7.gradInputs do
            table.insert(gradInputs7, rnn7.gradInputs[i]:clone())
         end
         rnn7:updateParameters(1)
         rnn7:zeroGradParameters()
      end
      
      -- nn.Recursor 
      
      local step = 1
      for i=1,nSteps7:size(1) do
         for j=1,nSteps7[i] do
            mytester:assertTensorEq(outputs9[step], rnn10:forward(inputs7[step]), 0.000001, "Recursor "..torch.type(rnn10).." remember forward err "..step)
            step = step + 1
         end
      end
      
      rnn10:forget()
      
      local step = 1
      for i=1,nSteps7:size(1) do
         for j=1,nSteps7[i] do
            mytester:assertTensorEq(outputs9[step], rnn10:forward(inputs7[step]), 0.000001, "Recursor "..torch.type(rnn10).." remember forward2 err "..step)
            step = step + 1
         end
      end
      
      rnn10:forget()
      
      local step = 1
      local outputs10, gradOutputs10, gradInputs10 = {}, {}, {}
      for i=1,nSteps7:size(1) do
         local start = step
         local nStep = 0
         for j=1,nSteps7[i] do
            outputs10[step] = rnn10:forward(inputs7[step]):clone()
            step = step + 1
            nStep = nStep + 1
         end
         rnn10:maxBPTTstep(nSteps7[i])
         local nStep2 = 0
         for s=step-1,start,-1 do
            gradInputs10[s] = rnn10:backward(inputs7[s], gradOutputs7[s]):clone()
            nStep2 = nStep2 + 1
         end
         assert(nStep == nStep2)
         rnn10:updateParameters(1)
         rnn10:zeroGradParameters()
      end
      
      local step = 1
      for i=1,nSteps7:size(1) do
         for j=1,nSteps7[i] do
            mytester:assertTensorEq(gradInputs10[step], gradInputs7[step], 0.0000001, "Recursor "..torch.type(rnn7).." remember variable backward err "..i.." "..j)
            mytester:assertTensorEq(outputs10[step], outputs7[step], 0.0000001, "Recursor "..torch.type(rnn7).." remember variable forward err "..i.." "..j)
            step = step + 1
         end
      end
      
      -- nn.Sequencer
      
      local seq = nn.Sequencer(rnn8)
      seq:remember('both')
      local outputs8, gradInputs8 = {}, {}
      local step = 1
      for i=1,nSteps7:size(1) do
         local inputs8 = _.slice(inputs7,step,step+nSteps7[i]-1)
         local gradOutputs8 = _.slice(gradOutputs7,step,step+nSteps7[i]-1)
         outputs8[i] = _.map(seq:forward(inputs8), function(k,v) return v:clone() end)
         gradInputs8[i] = _.map(seq:backward(inputs8, gradOutputs8), function(k,v) return v:clone() end)
         seq:updateParameters(1)
         seq:zeroGradParameters()
         step = step + nSteps7[i]
      end
      
      local step = 1
      for i=1,nSteps7:size(1) do
         for j=1,nSteps7[i] do
            mytester:assertTensorEq(gradInputs8[i][j], gradInputs7[step], 0.0000001, "Sequencer "..torch.type(rnn7).." remember variable backward err "..i.." "..j)
            mytester:assertTensorEq(outputs8[i][j], outputs7[step], 0.0000001, "Sequencer "..torch.type(rnn7).." remember variable forward err "..i.." "..j)
            step = step + 1
         end
      end
      
      local params7 = rnn7:parameters()
      local params8 = rnn8:parameters()
      for i=1,#params7 do
         mytester:assertTensorEq(params7[i], params8[i], 0.0000001, "Sequencer "..torch.type(rnn7).." remember params err "..i)
      end
      
      -- test in evaluation mode with remember and variable rho
      local rnn7 = rnn:clone() -- a fresh copy (no hidden states)
      local params7 = rnn7:parameters()
      local params9 = rnn9:parameters() -- not a fresh copy
      for i,param in ipairs(rnn8:parameters()) do
         params7[i]:copy(param)
         params9[i]:copy(param)
      end
      
      rnn7:evaluate()
      rnn9:evaluate()
      rnn9:forget()
      
      local inputs7, outputs9 = {}, {}
      for step=1,nSteps7:sum() do
         inputs7[step] = torch.randn(batchSize, outputSize)
         outputs9[step] = rnn9:forward(inputs7[step]):clone()
      end
      
      local step = 1
      for i=1,nSteps7:size(1) do
         for j=1,nSteps7[i] do
            mytester:assertTensorEq(outputs9[step], rnn7:forward(inputs7[step]), 0.000001, "Sequencer "..torch.type(rnn7).." remember eval forward err "..step)
            step = step + 1
         end
      end
      
      rnn7:forget()
      
      local step = 1
      for i=1,nSteps7:size(1) do
         for j=1,nSteps7[i] do
            mytester:assertTensorEq(outputs9[step], rnn7:forward(inputs7[step]), 0.000001, "Sequencer "..torch.type(rnn7).." remember eval forward2 err "..step)
            step = step + 1
         end
      end
      
      rnn7:forget()
      
      local step = 1
      local outputs7 = {}
      for i=1,nSteps7:size(1) do
         for j=1,nSteps7[i] do
            outputs7[step] = rnn7:forward(inputs7[step]):clone()
            step = step + 1
         end
      end
      
      seq:remember('both')
      local outputs8 = {}
      local step = 1
      for i=1,nSteps7:size(1) do
         seq:evaluate()
         local inputs8 = _.slice(inputs7,step,step+nSteps7[i]-1)
         local gradOutputs8 = _.slice(gradOutputs7,step,step+nSteps7[i]-1)
         outputs8[i] = _.map(seq:forward(inputs8), function(k,v) return v:clone() end)
         step = step + nSteps7[i]
      end
      
      local step = 1
      for i=1,nSteps7:size(1) do
         for j=1,nSteps7[i] do
            mytester:assertTensorEq(outputs8[i][j], outputs7[step], 0.0000001, "Sequencer "..torch.type(rnn7).." remember variable eval forward err "..i.." "..j)
            step = step + 1
         end
      end
      
      -- test remember for training mode (with variable length) (from evaluation to training)
      
      rnn7:forget()
      rnn9:forget()
      
      rnn7:training()
      rnn9:training()
      
      rnn7:zeroGradParameters()
      seq:zeroGradParameters()
      rnn9:zeroGradParameters()
      
      local inputs7, outputs9 = {}, {}
      for step=1,nSteps7:sum() do
         inputs7[step] = torch.randn(batchSize, outputSize)
         outputs9[step] = rnn9:forward(inputs7[step]):clone()
      end
      
      local step = 1
      for i=1,nSteps7:size(1) do
         for j=1,nSteps7[i] do
            mytester:assertTensorEq(outputs9[step], rnn7:forward(inputs7[step]), 0.000001, "Sequencer "..torch.type(rnn7).." remember forward err "..step)
            step = step + 1
         end
      end
      
      rnn7:forget()
      
      local step = 1
      for i=1,nSteps7:size(1) do
         for j=1,nSteps7[i] do
            mytester:assertTensorEq(outputs9[step], rnn7:forward(inputs7[step]), 0.000001, "Sequencer "..torch.type(rnn7).." remember forward2 err "..step)
            step = step + 1
         end
      end
      
      rnn7:forget()
      
      local step = 1
      local outputs7, gradOutputs7, gradInputs7 = {}, {}, {}
      for i=1,nSteps7:size(1) do
         for j=1,nSteps7[i] do
            outputs7[step] = rnn7:forward(inputs7[step]):clone()
            gradOutputs7[step] = torch.randn(batchSize, outputSize)
            rnn7:backward(inputs7[step], gradOutputs7[step])
            step = step + 1
         end
         rnn7.rho = nSteps7[i]
         rnn7:backwardThroughTime()
         for i=1,#rnn7.gradInputs do
            table.insert(gradInputs7, rnn7.gradInputs[i]:clone())
         end
         rnn7:updateParameters(1)
         rnn7:zeroGradParameters()
      end
      
      seq:remember('both')
      local outputs8, gradInputs8 = {}, {}
      local step = 1
      for i=1,nSteps7:size(1) do
         seq:training()
         local inputs8 = _.slice(inputs7,step,step+nSteps7[i]-1)
         local gradOutputs8 = _.slice(gradOutputs7,step,step+nSteps7[i]-1)
         outputs8[i] = _.map(seq:forward(inputs8), function(k,v) return v:clone() end)
         gradInputs8[i] = _.map(seq:backward(inputs8, gradOutputs8), function(k,v) return v:clone() end)
         seq:updateParameters(1)
         seq:zeroGradParameters()
         step = step + nSteps7[i]
      end
      
      local step = 1
      for i=1,nSteps7:size(1) do
         for j=1,nSteps7[i] do
            mytester:assertTensorEq(gradInputs8[i][j], gradInputs7[step], 0.0000001, "Sequencer "..torch.type(rnn7).." remember variable backward err "..i.." "..j)
            mytester:assertTensorEq(outputs8[i][j], outputs7[step], 0.0000001, "Sequencer "..torch.type(rnn7).." remember variable forward err "..i.." "..j)
            step = step + 1
         end
      end
      
      local params7 = rnn7:parameters()
      local params8 = rnn8:parameters()
      for i=1,#params7 do
         mytester:assertTensorEq(params7[i], params8[i], 0.0000001, "Sequencer "..torch.type(rnn7).." remember params err "..i)
      end
   end
   testRemember(nn.Recurrent(outputSize, nn.Linear(outputSize, outputSize), feedbackModule:clone(), transferModule:clone(), nSteps7:max()))
   testRemember(nn.LSTM(outputSize, outputSize, nSteps7:max()))

   -- test in evaluation mode
   rnn3:evaluate()
   local outputs4 = rnn3:forward(inputs)
   local outputs4_ = _.map(outputs4, function(k,v) return v:clone() end)
   mytester:assert(#outputs4 == #outputs, "Sequencer evaluate output size err")
   for step,output in ipairs(outputs) do
      mytester:assertTensorEq(outputs4[step], output, 0.00001, "Sequencer evaluate output "..step)
   end
   local inputs5 = _.clone(inputs)
   table.remove(inputs5, nSteps) -- remove last input
   local outputs5 = rnn3:forward(inputs5)
   mytester:assert(#outputs5 == #outputs - 1, "Sequencer evaluate -1 output size err")
   for step,output in ipairs(outputs5) do
      mytester:assertTensorEq(outputs[step], output, 0.00001, "Sequencer evaluate -1 output "..step)
   end
   
   -- test evaluation with remember 
   rnn3:remember()
   rnn3:evaluate()
   rnn3:forget()
   local inputsA, inputsB = {inputs[1],inputs[2],inputs[3]}, {inputs[4],inputs[5]}
   local outputsA = _.map(rnn3:forward(inputsA), function(k,v) return v:clone() end)
   local outputsB = rnn3:forward(inputsB)
   mytester:assert(#outputsA == 3, "Sequencer evaluate-remember output size err A")
   mytester:assert(#outputsB == 2, "Sequencer evaluate-remember output size err B")
   local outputsAB = {unpack(outputsA)}
   outputsAB[4], outputsAB[5] = unpack(outputsB)
   for step,output in ipairs(outputs4_) do
      mytester:assertTensorEq(outputsAB[step], output, 0.00001, "Sequencer evaluate-remember output "..step)
   end
   
   -- test with non-recurrent module
   local inputSize = 10
   local inputs = {}
   for step=1,nSteps do
      inputs[step] = torch.randn(batchSize, inputSize)
   end
   local linear = nn.Euclidean(inputSize, outputSize)
   local seq, outputs, gradInputs
   for k=1,3 do
      outputs, gradInputs = {}, {}
      linear:zeroGradParameters()
      local clone = linear:clone()
      for step=1,nSteps do
         outputs[step] = linear:forward(inputs[step]):clone()
         gradInputs[step] = linear:backward(inputs[step], gradOutputs[step]):clone()
      end
      
      seq = nn.Sequencer(clone)
      local outputs2 = seq:forward(inputs)
      local gradInputs2 = seq:backward(inputs, gradOutputs)
      
      mytester:assert(#outputs2 == #outputs, "Sequencer output size err")
      mytester:assert(#gradInputs2 == #gradInputs, "Sequencer gradInputs size err")
      for step,output in ipairs(outputs) do
         mytester:assertTensorEq(outputs2[step], output, 0.00001, "Sequencer output "..step)
         mytester:assertTensorEq(gradInputs2[step], gradInputs[step], 0.00001, "Sequencer gradInputs "..step)
      end
   end
   
   local inputs3, gradOutputs3 = {}, {}
   for i=1,#inputs do
      inputs3[i] = inputs[i]:float()
      gradOutputs3[i] = gradOutputs[i]:float()
   end
   local seq3 = seq:float()
   local outputs3 = seq:forward(inputs3)
   local gradInputs3 = seq:backward(inputs3, gradOutputs3)
   
   -- test for zeroGradParameters
   local seq = nn.Sequencer(nn.Linear(inputSize,outputSize))
   seq:zeroGradParameters()
   seq:forward(inputs)
   seq:backward(inputs, gradOutputs)
   local params, gradParams = seq:parameters()
   for i,gradParam in ipairs(gradParams) do
      mytester:assert(gradParam:sum() ~= 0, 0.000001, "Sequencer:backward err "..i)
   end
   local param, gradParam = seq:getParameters()
   seq:zeroGradParameters()
   mytester:assert(gradParam:sum() == 0, 0.000001, "Sequencer:getParameters err")
   local params, gradParams = seq:parameters()
   for i,gradParam in ipairs(gradParams) do
      mytester:assert(gradParam:sum() == 0, 0.000001, "Sequencer:zeroGradParameters err "..i)
   end
   
   -- test with LSTM
   local outputSize = inputSize
   local lstm = nn.LSTM(inputSize, outputSize, nil, false)
   lstm:zeroGradParameters()
   local lstm2 = lstm:clone()
   
   local inputs, outputs, gradOutputs = {}, {}, {}
   for step=1,nSteps do
      inputs[step] = torch.randn(batchSize, inputSize)
      gradOutputs[step] = torch.randn(batchSize, outputSize)
   end
   local gradOutput1 = gradOutputs[2]:clone()
   for step=1,nSteps do
      outputs[step] = lstm:forward(inputs[step])
      lstm:backward(inputs[step], gradOutputs[step])
   end
   lstm:backwardThroughTime()
   
   local lstm3 = nn.Sequencer(lstm2)
   lstm3:zeroGradParameters()
   local outputs3 = lstm3:forward(inputs)
   local gradInputs3 = lstm3:backward(inputs, gradOutputs)
   mytester:assert(#outputs3 == #outputs, "Sequencer LSTM output size err")
   mytester:assert(#gradInputs3 == #rnn.gradInputs, "Sequencer LSTM gradInputs size err")
   for step,output in ipairs(outputs) do
      mytester:assertTensorEq(outputs3[step], output, 0.00001, "Sequencer LSTM output "..step)
      mytester:assertTensorEq(gradInputs3[step], lstm.gradInputs[step], 0.00001, "Sequencer LSTM gradInputs "..step)
   end
   mytester:assertTensorEq(gradOutputs[2], gradOutput1, 0.00001, "Sequencer lstm gradOutput modified error")
   
   -- test remember modes : 'both', 'eval' for training(), evaluate(), training()
   local lstm = nn.LSTM(5,5)
   local seq = nn.Sequencer(lstm)
   local inputTrain = {torch.randn(5), torch.randn(5), torch.randn(5)}
   local inputEval = {torch.randn(5)}

   -- this shouldn't fail
   local modes = {'both', 'eval'}
   for i, mode in ipairs(modes) do
     seq:remember(mode)

     -- do one epoch of training
     seq:training()
     seq:forward(inputTrain)
     seq:backward(inputTrain, inputTrain)

     -- evaluate
     seq:evaluate()
     seq:forward(inputEval)

     -- do another epoch of training
     seq:training()
     seq:forward(inputTrain)
     seq:backward(inputTrain, inputTrain)
   end
end

function rnntest.BiSequencer()
   local hiddenSize = 8
   local batchSize = 4
   local nStep = 3
   local fwd = nn.LSTM(hiddenSize, hiddenSize)
   local bwd = nn.LSTM(hiddenSize, hiddenSize)
   fwd:zeroGradParameters()
   bwd:zeroGradParameters()
   local brnn = nn.BiSequencer(fwd:clone(), bwd:clone())
   local inputs, gradOutputs = {}, {}
   for i=1,nStep do
      inputs[i] = torch.randn(batchSize, hiddenSize)
      gradOutputs[i] = torch.randn(batchSize, hiddenSize*2)
   end
   local outputs = brnn:forward(inputs)
   local gradInputs = brnn:backward(inputs, gradOutputs)
   mytester:assert(#inputs == #outputs, "BiSequencer #outputs error")
   mytester:assert(#inputs == #gradInputs, "BiSequencer #outputs error")
   
   -- forward
   local fwdSeq = nn.Sequencer(fwd)
   local bwdSeq = nn.Sequencer(bwd)
   local zip, join = nn.ZipTable(), nn.Sequencer(nn.JoinTable(1,1))
   local fwdOutputs = fwdSeq:forward(inputs)
   local bwdOutputs = _.reverse(bwdSeq:forward(_.reverse(inputs)))
   local zipOutputs = zip:forward{fwdOutputs, bwdOutputs}
   local outputs2 = join:forward(zipOutputs)
   for i,output in ipairs(outputs) do
      mytester:assertTensorEq(output, outputs2[i], 0.000001, "BiSequencer output err "..i)
   end
   
   -- backward
   local joinGradInputs = join:backward(zipOutputs, gradOutputs)
   local zipGradInputs = zip:backward({fwdOutputs, bwdOutputs}, joinGradInputs)
   local bwdGradInputs = _.reverse(bwdSeq:backward(_.reverse(inputs), _.reverse(zipGradInputs[2])))
   local fwdGradInputs = fwdSeq:backward(inputs, zipGradInputs[1])
   local gradInputs2 = zip:forward{fwdGradInputs, bwdGradInputs}
   for i,gradInput in ipairs(gradInputs) do
      local gradInput2 = gradInputs2[i]
      gradInput2[1]:add(gradInput2[2])
      mytester:assertTensorEq(gradInput, gradInput2[1], 0.000001, "BiSequencer gradInput err "..i)
   end
   
   -- params
   local brnn2 = nn.Sequential():add(fwd):add(bwd)
   local params, gradParams = brnn:parameters()
   local params2, gradParams2 = brnn2:parameters()
   mytester:assert(#params == #params2, "BiSequencer #params err")
   mytester:assert(#params == #gradParams, "BiSequencer #gradParams err")
   for i,param in pairs(params) do
      mytester:assertTensorEq(param, params2[i], 0.000001, "BiSequencer params err "..i)
      mytester:assertTensorEq(gradParams[i], gradParams2[i], 0.000001, "BiSequencer gradParams err "..i)
   end
   
   -- updateParameters
   brnn:updateParameters(0.1)
   brnn2:updateParameters(0.1)
   brnn:zeroGradParameters()
   brnn2:zeroGradParameters()
   for i,param in pairs(params) do
      mytester:assertTensorEq(param, params2[i], 0.000001, "BiSequencer params update err "..i)
      mytester:assertTensorEq(gradParams[i], gradParams2[i], 0.000001, "BiSequencer gradParams zero err "..i)
   end
end

function rnntest.BiSequencerLM()
   local hiddenSize = 8
   local batchSize = 4
   local nStep = 3
   local fwd = nn.LSTM(hiddenSize, hiddenSize)
   local bwd = nn.LSTM(hiddenSize, hiddenSize)
   fwd:zeroGradParameters()
   bwd:zeroGradParameters()
   local brnn = nn.BiSequencerLM(fwd:clone(), bwd:clone())
   local inputs, gradOutputs = {}, {}
   for i=1,nStep do
      inputs[i] = torch.randn(batchSize, hiddenSize)
      gradOutputs[i] = torch.randn(batchSize, hiddenSize*2)
   end
   local outputs = brnn:forward(inputs)
   local gradInputs = brnn:backward(inputs, gradOutputs)
   mytester:assert(#inputs == #outputs, "BiSequencerLM #outputs error")
   mytester:assert(#inputs == #gradInputs, "BiSequencerLM #outputs error")
   
   -- forward
   local fwdSeq = nn.Sequencer(fwd)
   local bwdSeq = nn.Sequencer(bwd)
   local merge = nn.Sequential():add(nn.ZipTable()):add(nn.Sequencer(nn.JoinTable(1,1)))
   
   local fwdOutputs = fwdSeq:forward(_.first(inputs, #inputs-1))
   local bwdOutputs = _.reverse(bwdSeq:forward(_.reverse(_.last(inputs, #inputs-1))))
   
   local fwdMergeInputs = _.clone(fwdOutputs)
   table.insert(fwdMergeInputs, 1, fwdOutputs[1]:clone():zero())
   local bwdMergeInputs = _.clone(bwdOutputs)
   table.insert(bwdMergeInputs, bwdOutputs[1]:clone():zero())
   
   local outputs2 = merge:forward{fwdMergeInputs, bwdMergeInputs}
   
   for i,output in ipairs(outputs) do
      mytester:assertTensorEq(output, outputs2[i], 0.000001, "BiSequencerLM output err "..i)
   end
   
   -- backward
   local mergeGradInputs = merge:backward({fwdMergeInputs, bwdMergeInputs}, gradOutputs)
   
   local bwdGradInputs = _.reverse(bwdSeq:backward(_.reverse(_.last(inputs, #inputs-1)), _.reverse(_.first(mergeGradInputs[2], #inputs-1))))
   local fwdGradInputs = fwdSeq:backward(_.first(inputs, #inputs-1), _.last(mergeGradInputs[1], #inputs-1))
   
   for i,gradInput in ipairs(gradInputs) do
      local gradInput2
      if i == 1 then
         gradInput2 = fwdGradInputs[1]
      elseif i == #inputs then
         gradInput2 = bwdGradInputs[#inputs-1]
      else
         gradInput2 = fwdGradInputs[i]:clone()
         gradInput2:add(bwdGradInputs[i-1])
      end
      mytester:assertTensorEq(gradInput, gradInput2, 0.000001, "BiSequencerLM gradInput err "..i)
   end
   
   -- params
   local brnn2 = nn.Sequential():add(fwd):add(bwd)
   local params, gradParams = brnn:parameters()
   local params2, gradParams2 = brnn2:parameters()
   mytester:assert(#params == #params2, "BiSequencerLM #params err")
   mytester:assert(#params == #gradParams, "BiSequencerLM #gradParams err")
   for i,param in pairs(params) do
      mytester:assertTensorEq(param, params2[i], 0.000001, "BiSequencerLM params err "..i)
      mytester:assertTensorEq(gradParams[i], gradParams2[i], 0.000001, "BiSequencerLM gradParams err "..i)
   end
   
   -- updateParameters
   brnn:updateParameters(0.1)
   brnn2:updateParameters(0.1)
   brnn:zeroGradParameters()
   brnn2:zeroGradParameters()
   for i,param in pairs(params) do
      mytester:assertTensorEq(param, params2[i], 0.000001, "BiSequencerLM params update err "..i)
      mytester:assertTensorEq(gradParams[i], gradParams2[i], 0.000001, "BiSequencerLM gradParams zero err "..i)
   end
end

function rnntest.Repeater()
   local batchSize = 4
   local inputSize = 10
   local outputSize = 7
   local nSteps = 5 
   local inputModule = nn.Linear(inputSize, outputSize)
   local transferModule = nn.Sigmoid()
   -- test MLP feedback Module (because of Module:representations())
   local feedbackModule = nn.Linear(outputSize, outputSize)
   -- rho = nSteps
   local rnn = nn.Recurrent(outputSize, inputModule, feedbackModule, transferModule, nSteps)
   local rnn2 = rnn:clone()
   
   local inputs, outputs, gradOutputs = {}, {}, {}
   local input = torch.randn(batchSize, inputSize)
   for step=1,nSteps do
      outputs[step] = rnn:forward(input)
      gradOutputs[step] = torch.randn(batchSize, outputSize)
      rnn:backward(input, gradOutputs[step])
   end
   rnn:backwardThroughTime()
   
   local rnn3 = nn.Repeater(rnn2, nSteps)
   local outputs3 = rnn3:forward(input)
   local gradInput3 = rnn3:backward(input, gradOutputs)
   mytester:assert(#outputs3 == #outputs, "Repeater output size err")
   mytester:assert(#outputs3 == #rnn.gradInputs, "Repeater gradInputs size err")
   local gradInput = rnn.gradInputs[1]:clone():zero()
   for step,output in ipairs(outputs) do
      mytester:assertTensorEq(outputs3[step], output, 0.00001, "Repeater output "..step)
      gradInput:add(rnn.gradInputs[step])
   end
   mytester:assertTensorEq(gradInput3, gradInput, 0.00001, "Repeater gradInput err")
   
   -- test with Recursor
   
   local inputModule = nn.Linear(inputSize, outputSize)
   local transferModule = nn.Sigmoid()
   -- test MLP feedback Module (because of Module:representations())
   local feedbackModule = nn.Linear(outputSize, outputSize)
   -- rho = nSteps
   local rnn = nn.Recurrent(outputSize, inputModule, feedbackModule, transferModule, nSteps)
   local rnn2 = rnn:clone()
   
   local rnn3 = nn.Repeater(rnn, nSteps)
   local rnn4 = nn.Repeater(nn.Sequential():add(nn.Identity()):add(rnn2), nSteps)
   
   rnn3:zeroGradParameters()
   rnn4:zeroGradParameters()
   
   local outputs = rnn3:forward(input)
   local outputs2 = rnn4:forward(input)
   
   local gradInput = rnn3:backward(input, gradOutputs)
   local gradInput2 = rnn4:backward(input, gradOutputs)
   
   mytester:assert(#outputs == #outputs2, "Repeater output size err")
   for i=1,#outputs do
      mytester:assertTensorEq(outputs[i], outputs2[i], 0.0000001, "Repeater(Recursor) output err")
   end
   mytester:assertTensorEq(gradInput, gradInput2, 0.000001, "Repeater(Recursor) gradInput err")
   
   rnn3:updateParameters(1)
   rnn4:updateParameters(1)
   
   local params, gradParams = rnn3:parameters()
   local params2, gradParams2 = rnn4:parameters()
   
   for i=1,#params do
      mytester:assertTensorEq(params[i], params2[i], 0.0000001, "Repeater(Recursor) param err "..i)
      mytester:assertTensorEq(gradParams[i], gradParams2[i], 0.0000001, "Repeater(Recursor) gradParam err "..i)
   end
end

function rnntest.SequencerCriterion()
   local batchSize = 4
   local inputSize = 10
   local outputSize = 7
   local nSteps = 5  
   local criterion = nn.ClassNLLCriterion()
   local sc = nn.SequencerCriterion(criterion:clone())
   local input = {}
   local target = {}
   local err2 = 0
   local gradInput2 = {}
   for i=1,nSteps do
      input[i] = torch.randn(batchSize, inputSize)
      target[i] = torch.randperm(inputSize):narrow(1,1,batchSize)
      err2 = err2 + criterion:forward(input[i], target[i])
      gradInput2[i] = criterion:backward(input[i], target[i]):clone()
   end
   local err = sc:forward(input, target)
   mytester:asserteq(err, err2, 0.000001, "SequencerCriterion forward err") 
   local gradInput = sc:backward(input, target)
   for i=1,nSteps do
      mytester:assertTensorEq(gradInput[i], gradInput2[i], 0.000001, "SequencerCriterion backward err "..i)
   end
   mytester:assert(sc.isStateless, "SequencerCriterion stateless error")
end

function rnntest.RecurrentAttention()
   -- so basically, I know that this works because I used it to 
   -- reproduce a paper's results. So all future RecurrentAttention
   -- versions should match the behavior of this RATest class.
   -- Yeah, its ugly, but it's a unit test, so kind of hidden :
   local RecurrentAttention, parent = torch.class("nn.RATest", "nn.AbstractSequencer")

   function RecurrentAttention:__init(rnn, action, nStep, hiddenSize)
      parent.__init(self)
      assert(torch.isTypeOf(rnn, 'nn.AbstractRecurrent'))
      assert(torch.isTypeOf(action, 'nn.Module'))
      assert(torch.type(nStep) == 'number')
      assert(torch.type(hiddenSize) == 'table')
      assert(torch.type(hiddenSize[1]) == 'number', "Does not support table hidden layers" )
      
      self.rnn = rnn
      self.rnn.copyInputs = true
      self.action = action -- samples an x,y actions for each example
      self.hiddenSize = hiddenSize
      self.nStep = nStep
      
      self.modules = {self.rnn, self.action}
      self.sharedClones = {self.action:sharedClone()} -- action clones
      
      self.output = {} -- rnn output
      self.actions = {} -- action output
      
      self.forwardActions = false
      
      self.gradHidden = {}
   end

   function RecurrentAttention:updateOutput(input)
      self.rnn:forget()
      local nDim = input:dim()
      
      for step=1,self.nStep do
         -- we maintain a copy of action (with shared params) for each time-step
         local action = self:getStepModule(step)
         
         if step == 1 then
            -- sample an initial starting actions by forwarding zeros through the action
            self._initInput = self._initInput or input.new()
            self._initInput:resize(input:size(1),table.unpack(self.hiddenSize)):zero()
            self.actions[1] = action:updateOutput(self._initInput)
         else
            -- sample actions from previous hidden activation (rnn output)
            self.actions[step] = action:updateOutput(self.output[step-1])
         end
         
         -- rnn handles the recurrence internally
         local output = self.rnn:updateOutput{input, self.actions[step]}
         self.output[step] = self.forwardActions and {output, self.actions[step]} or output
      end
      
      return self.output
   end

   function RecurrentAttention:updateGradInput(input, gradOutput)
      assert(self.rnn.step - 1 == self.nStep, "inconsistent rnn steps")
      assert(torch.type(gradOutput) == 'table', "expecting gradOutput table")
      assert(#gradOutput == self.nStep, "gradOutput should have nStep elements")
       
      -- backward through the action
      for step=self.nStep,1,-1 do
         local action = self:getStepModule(step)
         
         local gradOutput_, gradAction_ = gradOutput[step], action.output:clone():zero()
         if self.forwardActions then
            gradOutput_, gradAction_ = unpack(gradOutput[step])
         end
         
         if step == self.nStep then
            self.gradHidden[step] = nn.rnn.recursiveCopy(self.gradHidden[step], gradOutput_)
         else
            -- gradHidden = gradOutput + gradAction
            nn.rnn.recursiveAdd(self.gradHidden[step], gradOutput_)
         end
         
         if step == 1 then
            -- backward through initial starting actions
            action:updateGradInput(self._initInput, gradAction_ or action.output)
         else
            -- Note : gradOutput is ignored by REINFORCE modules so we give action.output as a dummy variable
            local gradAction = action:updateGradInput(self.output[step-1], gradAction_)
            self.gradHidden[step-1] = nn.rnn.recursiveCopy(self.gradHidden[step-1], gradAction)
         end
      end
      
      -- backward through the rnn layer
      for step=1,self.nStep do
         self.rnn.step = step + 1
         self.rnn:updateGradInput(input, self.gradHidden[step])
      end
      -- back-propagate through time (BPTT)
      self.rnn:updateGradInputThroughTime()
      
      for step=self.nStep,1,-1 do
         local gradInput = self.rnn.gradInputs[step][1]
         if step == self.nStep then
            self.gradInput:resizeAs(gradInput):copy(gradInput)
         else
            self.gradInput:add(gradInput)
         end
      end

      return self.gradInput
   end

   function RecurrentAttention:accGradParameters(input, gradOutput, scale)
      assert(self.rnn.step - 1 == self.nStep, "inconsistent rnn steps")
      assert(torch.type(gradOutput) == 'table', "expecting gradOutput table")
      assert(#gradOutput == self.nStep, "gradOutput should have nStep elements")
       
      -- backward through the action layers
      for step=self.nStep,1,-1 do
         local action = self:getStepModule(step)
         local gradAction_ = self.forwardActions and gradOutput[step][2] or action.output:clone():zero()
               
         if step == 1 then
            -- backward through initial starting actions
            action:accGradParameters(self._initInput, gradAction_, scale)
         else
            -- Note : gradOutput is ignored by REINFORCE modules so we give action.output as a dummy variable
            action:accGradParameters(self.output[step-1], gradAction_, scale)
         end
      end
      
      -- backward through the rnn layer
      for step=1,self.nStep do
         self.rnn.step = step + 1
         self.rnn:accGradParameters(input, self.gradHidden[step], scale)
      end
      -- back-propagate through time (BPTT)
      self.rnn:accGradParametersThroughTime()
   end

   function RecurrentAttention:accUpdateGradParameters(input, gradOutput, lr)
      assert(self.rnn.step - 1 == self.nStep, "inconsistent rnn steps")
      assert(torch.type(gradOutput) == 'table', "expecting gradOutput table")
      assert(#gradOutput == self.nStep, "gradOutput should have nStep elements")
       
      -- backward through the action layers
      for step=self.nStep,1,-1 do
         local action = self:getStepModule(step)
         local gradAction_ = self.forwardActions and gradOutput[step][2] or action.output:clone():zero()
         
         if step == 1 then
            -- backward through initial starting actions
            action:accUpdateGradParameters(self._initInput, gradAction_, lr)
         else
            -- Note : gradOutput is ignored by REINFORCE modules so we give action.output as a dummy variable
            action:accUpdateGradParameters(self.output[step-1], gradAction_, lr)
         end
      end
      
      -- backward through the rnn layer
      for step=1,self.nStep do
         self.rnn.step = step + 1
         self.rnn:accUpdateGradParameters(input, self.gradHidden[step], lr)
      end
      -- back-propagate through time (BPTT)
      self.rnn:accUpdateGradParametersThroughTime()
   end

   function RecurrentAttention:type(type)
      self._input = nil
      self._actions = nil
      self._crop = nil
      self._pad = nil
      self._byte = nil
      return parent.type(self, type)
   end

   function RecurrentAttention:__tostring__()
      local tab = '  '
      local line = '\n'
      local ext = '  |    '
      local extlast = '       '
      local last = '   ... -> '
      local str = torch.type(self)
      str = str .. ' {'
      str = str .. line .. tab .. 'action : ' .. tostring(self.action):gsub(line, line .. tab .. ext)
      str = str .. line .. tab .. 'rnn     : ' .. tostring(self.rnn):gsub(line, line .. tab .. ext)
      str = str .. line .. '}'
      return str
   end


   if not pcall(function() require "image" end) then return end -- needs the image package
   
   local opt = {
      glimpseDepth = 3,
      glimpseHiddenSize = 20,
      glimpsePatchSize = 8,
      locatorHiddenSize = 20,
      imageHiddenSize = 20,
      hiddenSize = 20,
      rho = 5,
      locatorStd = 0.1,
      inputSize = 28,
      nClass = 10,
      batchSize = 4
   }
   
   -- glimpse network (rnn input layer) 
   local locationSensor = nn.Sequential()
   locationSensor:add(nn.SelectTable(2))
   locationSensor:add(nn.Linear(2, opt.locatorHiddenSize))
   locationSensor:add(nn.ReLU())

   local glimpseSensor = nn.Sequential()
   glimpseSensor:add(nn.SpatialGlimpse(opt.glimpsePatchSize, opt.glimpseDepth, opt.glimpseScale))
   glimpseSensor:add(nn.Collapse(3))
   glimpseSensor:add(nn.Linear(1*(opt.glimpsePatchSize^2)*opt.glimpseDepth, opt.glimpseHiddenSize))
   glimpseSensor:add(nn.ReLU())

   local glimpse = nn.Sequential()
   --glimpse:add(nn.PrintSize("preglimpse"))
   glimpse:add(nn.ConcatTable():add(locationSensor):add(glimpseSensor))
   glimpse:add(nn.JoinTable(1,1))
   glimpse:add(nn.Linear(opt.glimpseHiddenSize+opt.locatorHiddenSize, opt.imageHiddenSize))
   glimpse:add(nn.ReLU())
   glimpse:add(nn.Linear(opt.imageHiddenSize, opt.hiddenSize))

   -- recurrent neural network
   local rnn = nn.Recurrent(
      opt.hiddenSize, 
      glimpse,
      nn.Linear(opt.hiddenSize, opt.hiddenSize), 
      nn.ReLU(), 99999
   )

   -- output layer (actions)
   local locator = nn.Sequential()
   locator:add(nn.Linear(opt.hiddenSize, 2))
   locator:add(nn.HardTanh())
   
   -- model is a reinforcement learning agent
   local rva2 = nn.RATest(rnn:clone(), locator:clone(), opt.rho, {opt.hiddenSize})
   local rva = nn.RecurrentAttention(rnn:clone(), locator:clone(), opt.rho, {opt.hiddenSize})
   
   local input = torch.randn(opt.batchSize,1,opt.inputSize,opt.inputSize)
   local gradOutput = {}
   for step=1,opt.rho do
      table.insert(gradOutput, torch.randn(opt.batchSize, opt.hiddenSize))
   end
   
   -- now we compare to the nn.RATest class (which, we know, works)
   rva:zeroGradParameters()
   rva2:zeroGradParameters()
   
   local output = rva:forward(input)
   local output2 = rva2:forward(input)
   
   mytester:assert(#output == #output2, "RecurrentAttention #output err")
   for i=1,#output do
      mytester:assertTensorEq(output[i], output2[i], 0.0000001, "RecurrentAttention output err "..i)
   end
   
   local gradInput = rva:backward(input, gradOutput)
   local gradInput2 = rva2:backward(input, gradOutput)
   
   mytester:assertTensorEq(gradInput, gradInput2, 0.0000001, "RecurrentAttention gradInput err")
   
   rva:updateParameters(1)
   rva2:updateParameters(1)
   
   local params, gradParams = rva:parameters()
   local params2, gradParams2 = rva2:parameters()
   
   for i=1,#params do
      mytester:assertTensorEq(params[i], params2[i], 0.0000001, "RecurrentAttention, param err "..i)
      mytester:assertTensorEq(gradParams[i], gradParams2[i], 0.0000001, "RecurrentAttention, gradParam err "..i)
   end
   
   -- test with explicit recursor
   
   -- model is a reinforcement learning agent
   local rva2 = nn.RATest(rnn:clone(), locator:clone(), opt.rho, {opt.hiddenSize})
   local rva = nn.RecurrentAttention(nn.Recursor(rnn:clone()), locator:clone(), opt.rho, {opt.hiddenSize})
   
   local input = torch.randn(opt.batchSize,1,opt.inputSize,opt.inputSize)
   local gradOutput = {}
   for step=1,opt.rho do
      table.insert(gradOutput, torch.randn(opt.batchSize, opt.hiddenSize))
   end
   
   -- now we compare to the nn.RATest class (which, we know, works)
   rva:zeroGradParameters()
   rva2:zeroGradParameters()
   
   local output = rva:forward(input)
   local output2 = rva2:forward(input)
   
   mytester:assert(#output == #output2, "RecurrentAttention(Recursor) #output err")
   for i=1,#output do
      mytester:assertTensorEq(output[i], output2[i], 0.0000001, "RecurrentAttention(Recursor) output err "..i)
   end
   
   local gradInput = rva:backward(input, gradOutput)
   local gradInput2 = rva2:backward(input, gradOutput)
   
   mytester:assertTensorEq(gradInput, gradInput2, 0.0000001, "RecurrentAttention(Recursor) gradInput err")
   
   rva:updateParameters(1)
   rva2:updateParameters(1)
   
   local params, gradParams = rva:parameters()
   local params2, gradParams2 = rva2:parameters()
   
   for i=1,#params do
      mytester:assertTensorEq(params[i], params2[i], 0.0000001, "RecurrentAttention(Recursor), param err "..i)
      mytester:assertTensorEq(gradParams[i], gradParams2[i], 0.0000001, "RecurrentAttention(Recursor), gradParam err "..i)
   end
   
end
   
function rnntest.LSTM_nn_vs_nngraph()
   local model = {}
   -- match the successful https://github.com/wojzaremba/lstm
   -- We want to make sure our LSTM matches theirs.
   -- Also, the ugliest unit test you have every seen.
   -- Resolved 2-3 annoying bugs with it.
   local success = pcall(function() require 'nngraph' end)
   if not success then
      return
   end
   
   local vocabSize = 100
   local inputSize = 30
   local batchSize = 4
   local nLayer = 2
   local dropout = 0
   local nStep = 10
   local lr = 1
   
   -- build nn equivalent of nngraph model
   local model2 = nn.Sequential()
   local container2 = nn.Container()
   container2:add(nn.LookupTable(vocabSize, inputSize))
   model2:add(container2:get(1))
   local dropout2 = nn.Dropout(dropout)
   model2:add(dropout2)
   model2:add(nn.SplitTable(1,2))
   container2:add(nn.FastLSTM(inputSize, inputSize))
   model2:add(nn.Sequencer(container2:get(2)))
   model2:add(nn.Sequencer(nn.Dropout(0)))
   container2:add(nn.FastLSTM(inputSize, inputSize))
   model2:add(nn.Sequencer(container2:get(3)))
   model2:add(nn.Sequencer(nn.Dropout(0)))
   container2:add(nn.Linear(inputSize, vocabSize))
   local mlp = nn.Sequential():add(container2:get(4)):add(nn.LogSoftMax()) -- test double encapsulation
   model2:add(nn.Sequencer(mlp))
   
   local criterion2 = nn.ModuleCriterion(nn.SequencerCriterion(nn.ClassNLLCriterion()), nil, nn.SplitTable(1,1))
   
   
   -- nngraph model 
   local container = nn.Container()
   local lstmId = 1
   local function lstm(x, prev_c, prev_h)
      -- Calculate all four gates in one go
      local i2h = nn.Linear(inputSize, 4*inputSize)
      local dummy = nn.Container()
      dummy:add(i2h)
      i2h = i2h(x)
      local h2h = nn.LinearNoBias(inputSize, 4*inputSize)
      dummy:add(h2h)
      h2h = h2h(prev_h)
      container:add(dummy)
      local gates = nn.CAddTable()({i2h, h2h})

      -- Reshape to (batch_size, n_gates, hid_size)
      -- Then slize the n_gates dimension, i.e dimension 2
      local reshaped_gates =  nn.Reshape(4,inputSize)(gates)
      local sliced_gates = nn.SplitTable(2)(reshaped_gates)

      -- Use select gate to fetch each gate and apply nonlinearity
      local in_gate          = nn.Sigmoid()(nn.SelectTable(1)(sliced_gates))
      local in_transform     = nn.Tanh()(nn.SelectTable(2)(sliced_gates))
      local forget_gate      = nn.Sigmoid()(nn.SelectTable(3)(sliced_gates))
      local out_gate         = nn.Sigmoid()(nn.SelectTable(4)(sliced_gates))

      local next_c           = nn.CAddTable()({
         nn.CMulTable()({forget_gate, prev_c}),
         nn.CMulTable()({in_gate,     in_transform})
      })
      local next_h           = nn.CMulTable()({out_gate, nn.Tanh()(next_c)})
      lstmId = lstmId + 1
      return next_c, next_h
   end
   local function create_network()
      local x                = nn.Identity()()
      local y                = nn.Identity()()
      local prev_s           = nn.Identity()()
      local lookup = nn.LookupTable(vocabSize, inputSize)
      container:add(lookup)
      local identity = nn.Identity()
      lookup = identity(lookup(x))
      local i                = {[0] = lookup}
      local next_s           = {}
      local split         = {prev_s:split(2 * nLayer)}
      for layer_idx = 1, nLayer do
         local prev_c         = split[2 * layer_idx - 1]
         local prev_h         = split[2 * layer_idx]
         local dropped        = nn.Dropout(dropout)(i[layer_idx - 1])
         local next_c, next_h = lstm(dropped, prev_c, prev_h)
         table.insert(next_s, next_c)
         table.insert(next_s, next_h)
         i[layer_idx] = next_h
      end
      
      local h2y              = nn.Linear(inputSize, vocabSize)
      container:add(h2y)
      local dropped          = nn.Dropout(dropout)(i[nLayer])
      local pred             = nn.LogSoftMax()(h2y(dropped))
      local err              = nn.ClassNLLCriterion()({pred, y})
      local module           = nn.gModule({x, y, prev_s}, {err, nn.Identity()(next_s)})
      module:getParameters():uniform(-0.1, 0.1)
      module._lookup = identity
      return module
   end
   
   local function g_cloneManyTimes(net, T)
      local clones = {}
      local params, gradParams = net:parameters()
      local mem = torch.MemoryFile("w"):binary()
      assert(net._lookup)
      mem:writeObject(net)
      for t = 1, T do
         local reader = torch.MemoryFile(mem:storage(), "r"):binary()
         local clone = reader:readObject()
         reader:close()
         local cloneParams, cloneGradParams = clone:parameters()
         for i = 1, #params do
            cloneParams[i]:set(params[i])
            cloneGradParams[i]:set(gradParams[i])
         end
         clones[t] = clone
         collectgarbage()
      end
      mem:close()
      return clones
   end
   
   local model = {}
   local paramx, paramdx
   local core_network = create_network()
   
   -- sync nn with nngraph model
   local params, gradParams = container:getParameters()
   local params2, gradParams2 = container2:getParameters()
   params2:copy(params)
   container:zeroGradParameters()
   container2:zeroGradParameters()
   paramx, paramdx = core_network:getParameters()
   
   model.s = {}
   model.ds = {}
   model.start_s = {}
   for j = 0, nStep do
      model.s[j] = {}
      for d = 1, 2 * nLayer do
         model.s[j][d] = torch.zeros(batchSize, inputSize)
      end
   end
   for d = 1, 2 * nLayer do
      model.start_s[d] = torch.zeros(batchSize, inputSize)
      model.ds[d] = torch.zeros(batchSize, inputSize)
   end
   model.core_network = core_network
   model.rnns = g_cloneManyTimes(core_network, nStep)
   model.norm_dw = 0
   model.err = torch.zeros(nStep)
   
   -- more functions for nngraph baseline
   local function g_replace_table(to, from)
     assert(#to == #from)
     for i = 1, #to do
       to[i]:copy(from[i])
     end
   end

   local function reset_ds()
     for d = 1, #model.ds do
       model.ds[d]:zero()
     end
   end
   
   local function reset_state(state)
     state.pos = 1
     if model ~= nil and model.start_s ~= nil then
       for d = 1, 2 * nLayer do
         model.start_s[d]:zero()
       end
     end
   end

   local function fp(state)
     g_replace_table(model.s[0], model.start_s)
     if state.pos + nStep > state.data:size(1) then
         error"Not Supposed to happen in this unit test"
     end
     for i = 1, nStep do
       local x = state.data[state.pos]
       local y = state.data[state.pos + 1]
       local s = model.s[i - 1]
       model.err[i], model.s[i] = unpack(model.rnns[i]:forward({x, y, s}))
       state.pos = state.pos + 1
     end
     g_replace_table(model.start_s, model.s[nStep])
     return model.err:mean()
   end

   model.dss = {}
   local function bp(state)
     paramdx:zero()
     local __, gradParams = core_network:parameters()
     for i=1,#gradParams do
        mytester:assert(gradParams[i]:sum() == 0)
     end
     reset_ds() -- backward of last step in each sequence is zero
     for i = nStep, 1, -1 do
       state.pos = state.pos - 1
       local x = state.data[state.pos]
       local y = state.data[state.pos + 1]
       local s = model.s[i - 1]
       local derr = torch.ones(1)
       local tmp = model.rnns[i]:backward({x, y, s}, {derr, model.ds,})[3]
       model.dss[i-1] = tmp
       g_replace_table(model.ds, tmp)
     end
     state.pos = state.pos + nStep
     paramx:add(-lr, paramdx)
   end
   
   -- inputs and targets (for nngraph implementation)
   local inputs = torch.Tensor(nStep*10, batchSize):random(1,vocabSize)

   -- is everything aligned between models?
   local params_, gradParams_ = container:parameters()
   local params2_, gradParams2_ = container2:parameters()

   for i=1,#params_ do
      mytester:assertTensorEq(params_[i], params2_[i], 0.00001, "nn vs nngraph unaligned params err "..i)
      mytester:assertTensorEq(gradParams_[i], gradParams2_[i], 0.00001, "nn vs nngraph unaligned gradParams err "..i)
   end
   
   -- forward 
   local state = {pos=1,data=inputs}
   local err = fp(state)
   
   local inputs2 = inputs:narrow(1,1,nStep):transpose(1,2)
   local targets2 = inputs:narrow(1,2,nStep):transpose(1,2)
   local outputs2 = model2:forward(inputs2)
   local err2 = criterion2:forward(outputs2, targets2)
   mytester:asserteq(err, err2/nStep, 0.0001, "nn vs nngraph err error")
   
   -- backward/update
   bp(state)
   
   local gradOutputs2 = criterion2:backward(outputs2, targets2)
   model2:backward(inputs2, gradOutputs2)
   model2:updateParameters(lr)
   model2:zeroGradParameters()
   
   for i=1,#gradParams2_ do
      mytester:assert(gradParams2_[i]:sum() == 0)
   end
   
   for i=1,#params_ do
      mytester:assertTensorEq(params_[i], params2_[i], 0.00001, "nn vs nngraph params err "..i)
   end
   
   for i=1,nStep do
      mytester:assertTensorEq(model.rnns[i]._lookup.output, dropout2.output:select(2,i), 0.0000001)
      mytester:assertTensorEq(model.rnns[i]._lookup.gradInput, dropout2.gradInput:select(2,i), 0.0000001)
   end
   
   -- next_c, next_h, next_c...
   for i=nStep-1,2,-1 do
      mytester:assertTensorEq(model.dss[i][1], container2:get(2).gradCells[i], 0.0000001, "gradCells1 err "..i)
      mytester:assertTensorEq(model.dss[i][2], container2:get(2)._gradOutputs[i] - container2:get(2).gradOutputs[i], 0.0000001, "gradOutputs1 err "..i)
      mytester:assertTensorEq(model.dss[i][3], container2:get(3).gradCells[i], 0.0000001, "gradCells2 err "..i)
      mytester:assertTensorEq(model.dss[i][4], container2:get(3)._gradOutputs[i] - container2:get(3).gradOutputs[i], 0.0000001, "gradOutputs2 err "..i)
   end
   
   for i=1,#params2_ do
      params2_[i]:copy(params_[i])
      gradParams_[i]:copy(gradParams2_[i])
   end
   
   local gradInputClone = dropout2.gradInput:select(2,1):clone()
   
   local start_s = _.map(model.start_s, function(k,v) return v:clone() end)
   mytester:assertTensorEq(start_s[1], container2:get(2).cells[nStep], 0.0000001)
   mytester:assertTensorEq(start_s[2], container2:get(2).outputs[nStep], 0.0000001)
   mytester:assertTensorEq(start_s[3], container2:get(3).cells[nStep], 0.0000001)
   mytester:assertTensorEq(start_s[4], container2:get(3).outputs[nStep], 0.0000001)
   
   -- and do it again
   -- forward 
   --reset_state(state)
   
   local inputs2 = inputs:narrow(1,nStep+1,nStep):transpose(1,2)
   local targets2 = inputs:narrow(1,nStep+2,nStep):transpose(1,2)
   model2:remember()
   local outputs2 = model2:forward(inputs2)
   
   local inputsClone, outputsClone, cellsClone = container2:get(2).inputs[nStep+1]:clone(), container2:get(2).outputs[nStep]:clone(), container2:get(2).cells[nStep]:clone()
   local err2 = criterion2:forward(outputs2, targets2)
   local state = {pos=nStep+1,data=inputs}
   local err = fp(state)
   mytester:asserteq(err2/nStep, err, 0.00001, "nn vs nngraph err error")
   -- backward/update
   bp(state)
   
   local gradOutputs2 = criterion2:backward(outputs2, targets2)
   model2:backward(inputs2, gradOutputs2)
   
   mytester:assertTensorEq(start_s[1], container2:get(2).cells[nStep], 0.0000001)
   mytester:assertTensorEq(start_s[2], container2:get(2).outputs[nStep], 0.0000001)
   mytester:assertTensorEq(start_s[3], container2:get(3).cells[nStep], 0.0000001)
   mytester:assertTensorEq(start_s[4], container2:get(3).outputs[nStep], 0.0000001)
   
   model2:updateParameters(lr)
   
   mytester:assertTensorEq(inputsClone, container2:get(2).inputs[nStep+1], 0.000001)
   mytester:assertTensorEq(outputsClone, container2:get(2).outputs[nStep], 0.000001)
   mytester:assertTensorEq(cellsClone, container2:get(2).cells[nStep], 0.000001)
   
   -- next_c, next_h, next_c...
   for i=nStep-1,2,-1 do
      mytester:assertTensorEq(model.dss[i][1], container2:get(2).gradCells[i+nStep], 0.0000001, "gradCells1 err "..i)
      mytester:assertTensorEq(model.dss[i][2], container2:get(2)._gradOutputs[i+nStep] - container2:get(2).gradOutputs[i+nStep], 0.0000001, "gradOutputs1 err "..i)
      mytester:assertTensorEq(model.dss[i][3], container2:get(3).gradCells[i+nStep], 0.0000001, "gradCells2 err "..i)
      mytester:assertTensorEq(model.dss[i][4], container2:get(3)._gradOutputs[i+nStep] - container2:get(3).gradOutputs[i+nStep], 0.0000001, "gradOutputs2 err "..i)
   end
   
   mytester:assertTensorNe(gradInputClone, dropout2.gradInput:select(2,1), 0.0000001, "lookup table gradInput1 err")
   
   for i=1,nStep do
      mytester:assertTensorEq(model.rnns[i]._lookup.output, dropout2.output:select(2,i), 0.0000001, "lookup table output err "..i)
      mytester:assertTensorEq(model.rnns[i]._lookup.gradInput, dropout2.gradInput:select(2,i), 0.0000001, "lookup table gradInput err "..i)
   end
   
   for i=1,#params_ do
      mytester:assertTensorEq(params_[i], params2_[i], 0.00001, "nn vs nngraph second update params err "..i)
   end
end

-- https://github.com/Element-Research/rnn/issues/28
function rnntest.Recurrent_checkgrad()
   if not pcall(function() require 'optim' end) then return end

   local hiddenSize = 2
   local nIndex = 2
   local r = nn.Recurrent(hiddenSize, nn.LookupTable(nIndex, hiddenSize),
                    nn.Linear(hiddenSize, hiddenSize))

   local rnn = nn.Sequential()
   rnn:add(r)
   rnn:add(nn.Linear(hiddenSize, nIndex))
   rnn:add(nn.LogSoftMax())

   local criterion = nn.ClassNLLCriterion()
   local sequence = torch.Tensor{1, 2, 1, 2}:resize(4, 1)
   local parameters, grads = rnn:getParameters()
   
   function f(x)
      parameters:copy(x)
      -- Do the forward prop
      rnn:zeroGradParameters()
      local err = 0
      for i = 1, sequence:size(1) - 1 do
         local output = rnn:forward(sequence[i])
         err = err + criterion:forward(output, sequence[i + 1])
         local gradOutput = criterion:backward(output, sequence[i + 1])
         rnn:backward(sequence[i], gradOutput)
      end
      r:backwardThroughTime()
      r:forget()
      return err, grads
   end

   local err = optim.checkgrad(f, parameters:clone())
   mytester:assert(err < 0.0001, "Recurrent optim.checkgrad error")
end

function rnntest.LSTM_checkgrad()
   if not pcall(function() require 'optim' end) then return end

   local hiddenSize = 2
   local nIndex = 2
   local r = nn.LSTM(hiddenSize, hiddenSize)

   local rnn = nn.Sequential()
   rnn:add(r)
   rnn:add(nn.Linear(hiddenSize, nIndex))
   rnn:add(nn.LogSoftMax())

   local criterion = nn.ClassNLLCriterion()
   local inputs = torch.randn(4, 2)
   local targets = torch.Tensor{1, 2, 1, 2}:resize(4, 1)
   local parameters, grads = rnn:getParameters()
   
   function f(x)
      parameters:copy(x)
      -- Do the forward prop
      rnn:zeroGradParameters()
      local err = 0
      for i = 1, inputs:size(1) do
         local output = rnn:forward(inputs[i])
         err = err + criterion:forward(output, targets[i])
         local gradOutput = criterion:backward(output, targets[i])
         rnn:backward(inputs[i], gradOutput)
      end
      r:backwardThroughTime()
      r:forget()
      return err, grads
   end

   local err = optim.checkgrad(f, parameters:clone())
   mytester:assert(err < 0.0001, "LSTM optim.checkgrad error")
end

function rnntest.Recursor()
   local batchSize = 4
   local inputSize = 3
   local hiddenSize = 12
   local outputSize = 7
   local rho = 5 
   
   -- USE CASE 1. Recursor(Recurrent)
   
   local inputModule = nn.Linear(inputSize, outputSize)
   local transferModule = nn.Sigmoid()
   -- test MLP feedback Module (because of Module:representations())
   local feedbackModule = nn.Sequential()
   feedbackModule:add(nn.Linear(outputSize, hiddenSize))
   feedbackModule:add(nn.Sigmoid())
   feedbackModule:add(nn.Linear(hiddenSize, outputSize))
   local start = nn.Add(outputSize)
   
   local rnn = nn.Recurrent(start, nn.Identity(), feedbackModule, transferModule:clone(), rho)
   local re = nn.Recursor(nn.Sequential():add(inputModule):add(rnn), rho)
   re:zeroGradParameters()
   
   local re2 = nn.Recurrent(start:clone(), inputModule:clone(), feedbackModule:clone(), transferModule:clone(), rho)
   re2:zeroGradParameters()
   
   local inputs = {}
   local gradOutputs = {}
   local outputs, outputs2 = {}, {}
   local gradInputs = {}
   
   for i=1,rho do
      table.insert(inputs, torch.randn(batchSize, inputSize))
      table.insert(gradOutputs, torch.randn(batchSize, outputSize))
      -- forward
      table.insert(outputs, re:forward(inputs[i]))
      table.insert(outputs2, re2:forward(inputs[i]))
      -- backward
      re2:backward(inputs[i], gradOutputs[i])
   end
   
   re2:backwardThroughTime()
   re2:updateParameters(0.1)
   
   -- recursor requires reverse-time-step order during backward
   for i=rho,1,-1 do
      gradInputs[i] = re:backward(inputs[i], gradOutputs[i])
   end
   
   for i=1,rho do
      mytester:assertTensorEq(outputs[i], outputs2[i], 0.0000001, "Recursor(Recurrent) fwd err "..i)
      mytester:assertTensorEq(gradInputs[i], re2.gradInputs[i], 0.0000001, "Recursor(Recurrent) bwd err "..i)
   end
   
   re:updateParameters(0.1)
   
   local mlp = nn.Container():add(rnn.feedbackModule):add(rnn.startModule):add(inputModule)
   local mlp2 = nn.Container():add(re2.feedbackModule):add(re2.startModule):add(re2.inputModule)
   
   local params, gradParams = mlp:parameters()
   local params2, gradParams2 = mlp2:parameters()
   
   mytester:assert(#params == #params2, "Recursor(Recurrent) #params err")
   for i=1,#params do
      mytester:assertTensorEq(params[i], params2[i], 0.0000001, "Recursor(Recurrent) updateParameter err "..i)
      mytester:assertTensorEq(gradParams[i], gradParams2[i], 0.0000001, "Recursor(Recurrent) accGradParams err "..i)
   end
   
   -- USE CASE 2. Recursor(LSTM)
   
   local rnn = nn.LSTM(inputSize, outputSize)
   local re2 = rnn:clone()
   local re = nn.Recursor(nn.Sequential():add(rnn))
   re:zeroGradParameters()
   re2:zeroGradParameters()
   
   local outputs, outputs2 = {}, {}
   local gradInputs = {}
   
   for i=1,rho do
      -- forward
      table.insert(outputs, re:forward(inputs[i]))
      table.insert(outputs2, re2:forward(inputs[i]))
      -- backward
      re2:backward(inputs[i], gradOutputs[i])
   end
   
   re2:updateGradInputThroughTime()
   re2:accGradParametersThroughTime()
   re2:updateParameters(0.1)
   
   -- recursor requires reverse-time-step order during backward
   for i=rho,1,-1 do
      gradInputs[i] = re:backward(inputs[i], gradOutputs[i])
   end
   
   for i=1,rho do
      mytester:assertTensorEq(outputs[i], outputs2[i], 0.0000001, "Recursor(LSTM) fwd err "..i)
      mytester:assertTensorEq(gradInputs[i], re2.gradInputs[i], 0.0000001, "Recursor(LSTM) bwd err "..i)
   end
   
   re:updateParameters(0.1)
   
   local params, gradParams = rnn:parameters()
   local params2, gradParams2 = re2:parameters()
   
   mytester:assert(#params == #params2, "Recursor(LSTM) #params err")
   for i=1,#params do
      mytester:assertTensorEq(params[i], params2[i], 0.0000001, "Recursor(LSTM) updateParameter err "..i)
      mytester:assertTensorEq(gradParams[i], gradParams2[i], 0.0000001, "Recursor(LSTM) accGradParams err "..i)
   end
   
   -- USE CASE 3. Sequencer(Recursor)
   
   local re2 = nn.LSTM(inputSize, outputSize)
   local lstm2 = re2:clone()
   local rec = nn.Recursor(lstm2)
   local seq = nn.Sequencer(rec)
   mytester:assert(not rec.copyInputs)
   mytester:assert(not rec.copyGradOutputs)
   mytester:assert(not lstm2.copyInputs)
   mytester:assert(not lstm2.copyGradOutputs)
   
   seq:zeroGradParameters()
   re2:zeroGradParameters()
   
   local outputs = seq:forward(inputs)
   local gradInputs = seq:backward(inputs, gradOutputs)
   
   local outputs2 = {}
   for i=1,rho do
      table.insert(outputs2, re2:forward(inputs[i]))
      re2:backward(inputs[i], gradOutputs[i])
   end
   
   re2:updateGradInputThroughTime()
   re2:accGradParametersThroughTime()
   re2:updateParameters(0.1)
   
   for i=1,rho do
      mytester:assertTensorEq(outputs[i], outputs2[i], 0.0000001, "Sequencer(Recursor(LSTM)) fwd err "..i)
      mytester:assertTensorEq(gradInputs[i], re2.gradInputs[i], 0.0000001, "Sequencer(Recursor(LSTM)) bwd err "..i)
   end
   
   seq:updateParameters(0.1)
   
   local params, gradParams = seq:parameters()
   local params2, gradParams2 = re2:parameters()
   
   mytester:assert(#params == #params2, "Sequencer(Recursor(LSTM)) #params err")
   for i=1,#params do
      mytester:assertTensorEq(params[i], params2[i], 0.0000001, "Sequencer(Recursor(LSTM)) updateParameter err "..i)
      mytester:assertTensorEq(gradParams[i], gradParams2[i], 0.0000001, "Sequencer(Recursor(LSTM)) accGradParams err "..i)
   end
   
   -- USE CASE 4. Recursor(Recursor(LSTM))
   
   local rnn = nn.LSTM(inputSize, outputSize)
   local re2 = rnn:clone()
   local re = nn.Recursor(nn.Recursor(nn.Sequential():add(rnn)))
   re:zeroGradParameters()
   re2:zeroGradParameters()
   
   local outputs, outputs2 = {}, {}
   local gradInputs = {}
   
   for i=1,rho do
      -- forward
      table.insert(outputs, re:forward(inputs[i]))
      table.insert(outputs2, re2:forward(inputs[i]))
      -- backward
      re2:backward(inputs[i], gradOutputs[i])
   end
   
   re2:updateGradInputThroughTime()
   re2:accGradParametersThroughTime()
   re2:updateParameters(0.1)
   
   -- recursor requires reverse-time-step order during backward
   for i=rho,1,-1 do
      gradInputs[i] = re:backward(inputs[i], gradOutputs[i])
   end
   
   for i=1,rho do
      mytester:assertTensorEq(outputs[i], outputs2[i], 0.0000001, "Recursor(Recursor(LSTM)) fwd err "..i)
      mytester:assertTensorEq(gradInputs[i], re2.gradInputs[i], 0.0000001, "Recursor(Recursor(LSTM)) bwd err "..i)
   end
   
   re:updateParameters(0.1)
   
   local params, gradParams = rnn:parameters()
   local params2, gradParams2 = re2:parameters()
   
   mytester:assert(#params == #params2, "Recursor(Recursor(LSTM)) #params err")
   for i=1,#params do
      mytester:assertTensorEq(params[i], params2[i], 0.0000001, "Recursor(Recursor(LSTM)) updateParameter err "..i)
      mytester:assertTensorEq(gradParams[i], gradParams2[i], 0.0000001, "Recursor(Recursor(LSTM)) accGradParams err "..i)
   end
   
end

function rnntest.Recurrence()
   local batchSize = 4
   local inputSize = 10
   local outputSize = 12
   local rho = 3

   -- 1. compare to LSTM
   local lstm2 = nn.LSTM(inputSize, outputSize)
   local rm = lstm2.recurrentModule:clone()
   local seq2 = nn.Sequencer(lstm2)
   
   rm:insert(nn.FlattenTable(), 1)
   local recurrence = nn.Recurrence(rm, {{outputSize}, {outputSize}}, 1)
   local lstm = nn.Sequential():add(recurrence):add(nn.SelectTable(1))
   local seq = nn.Sequencer(lstm)
   
   local inputs, gradOutputs = {}, {}
   for i=1,rho do
      table.insert(inputs, torch.randn(batchSize, inputSize))
      table.insert(gradOutputs, torch.randn(batchSize, outputSize))
   end
   
   seq:zeroGradParameters()
   seq2:zeroGradParameters()
   
   local outputs = seq:forward(inputs)
   local outputs2 = seq2:forward(inputs)
   
   for i=1,rho do
      mytester:assertTensorEq(outputs[i], outputs2[i], 0.0000001, "Recurrence fwd err "..i)
   end
   
   local gradInputs = seq:backward(inputs, gradOutputs)
   local gradInputs2 = seq2:backward(inputs, gradOutputs)
   
   for i=1,rho do
      mytester:assertTensorEq(gradInputs[i], gradInputs2[i], 0.0000001, "Recurrence bwd err "..i)
   end
   
   seq:updateParameters(0.1)
   seq2:updateParameters(0.1)
   
   local params, gradParams = seq:parameters()
   local params2, gradParams2 = seq2:parameters()
   
   mytester:assert(#params == #params2, "Recurrence #params err")
   for i=1,#params do
      mytester:assertTensorEq(params[i], params2[i], 0.0000001, "Recurrence updateParameter err "..i)
      mytester:assertTensorEq(gradParams[i], gradParams2[i], 0.0000001, "Recurrence accGradParams err "..i)
   end
   
   -- 2. compare to simple RNN
   
   local nIndex = 50
   local hiddenSize = 20
   
   local inputLayer = nn.LookupTable(nIndex, hiddenSize)
   local feedbackLayer = nn.Linear(hiddenSize, hiddenSize)
   local outputLayer = nn.Linear(hiddenSize, outputSize)
   
   local rnn = nn.Recurrent(hiddenSize, inputLayer, feedbackLayer, nn.Sigmoid(), 99999 )
   rnn.startModule:share(rnn.feedbackModule, 'bias')
   
   -- just so the params are aligned
   local seq2_ = nn.Sequential()
      :add(nn.ParallelTable()
         :add(inputLayer)
         :add(feedbackLayer))
      :add(outputLayer)
   
   local seq2 = nn.Sequencer(nn.Sequential():add(rnn):add(outputLayer):add(nn.LogSoftMax()))
   
   local rm = nn.Sequential()
   :add(nn.ParallelTable()
      :add(inputLayer:clone())
      :add(feedbackLayer:clone()))
   :add(nn.CAddTable())
   :add(nn.Sigmoid())

   local seq = nn.Sequencer(nn.Sequential()
      :add(nn.Recurrence(rm, hiddenSize, 0))
      :add(outputLayer:clone())
      :add(nn.LogSoftMax()))
   
   local inputs, gradOutputs = {}, {}
   for i=1,rho do
      table.insert(inputs, torch.IntTensor(batchSize):random(1,nIndex))
      table.insert(gradOutputs, torch.randn(batchSize, outputSize))
   end
   
   seq:zeroGradParameters()
   seq2:zeroGradParameters()
   
   local outputs = seq:forward(inputs)
   local outputs2 = seq2:forward(inputs)
   
   for i=1,rho do
      mytester:assertTensorEq(outputs[i], outputs2[i], 0.0000001, "Recurrence RNN fwd err "..i)
   end
   
   seq:backward(inputs, gradOutputs)
   seq2:backward(inputs, gradOutputs)
   
   seq:updateParameters(0.1)
   seq2:updateParameters(0.1)
   
   local params, gradParams = seq:parameters()
   local params2, gradParams2 = seq2_:parameters()
   
   mytester:assert(#params == #params2, "Recurrence RNN #params err")
   for i=1,#params do
      mytester:assertTensorEq(params[i], params2[i], 0.0000001, "Recurrence RNN updateParameter err "..i)
      if i~= 3 then -- the gradBias isn't shared (else udpated twice)
         mytester:assertTensorEq(gradParams[i], gradParams2[i], 0.0000001, "Recurrence RNN accGradParams err "..i)
      end
   end
end

-- mock Recurrent and LSTM recurrentModules for UT
-- must be stateless
-- forwarding zeros must not return zeros -> use Sigmoid()
local function recurrentModule()
   local recurrent = nn.Sequential()
   local parallel = nn.ParallelTable()
   parallel:add(nn.Sigmoid()); parallel:add(nn.Identity())
   recurrent = nn.Sequential()
   recurrent:add(parallel)
   recurrent:add(nn.SelectTable(1))
   return recurrent
end

local function lstmModule()
   local recurrent = nn.Sequential()
   local parallel = nn.ParallelTable()
   parallel:add(nn.Sigmoid()); parallel:add(nn.Identity()); parallel:add(nn.Identity())
   recurrent = nn.Sequential()
   recurrent:add(parallel)
   recurrent:add(nn.NarrowTable(1, 2))
   return recurrent
end

local function firstElement(a)
   return torch.type(a) == 'table' and a[1] or a
end

function rnntest.MaskZero()
   local recurrents = {['recurrent'] = recurrentModule(), ['lstm'] = lstmModule()}
   -- Note we use lstmModule input signature and firstElement to prevent duplicate code
   for name, recurrent in pairs(recurrents) do
      -- test encapsulated module first
      -- non batch
      local i = torch.rand(10)
      local e = nn.Sigmoid():forward(i)
      local o = firstElement(recurrent:forward({i, torch.zeros(10), torch.zeros(10)}))
      mytester:assertlt(torch.norm(o - e), precision, 'mock ' .. name .. ' failed for non batch')
      -- batch
      local i = torch.rand(5, 10)
      local e = nn.Sigmoid():forward(i)
      local o = firstElement(recurrent:forward({i, torch.zeros(5, 10), torch.zeros(5, 10)}))
      mytester:assertlt(torch.norm(o - e), precision, 'mock ' .. name .. ' module failed for batch')
    
      -- test mask zero module now
      local module = nn.MaskZero(recurrent, 1)
      -- non batch forward
      local i = torch.rand(10)
      local e = firstElement(recurrent:forward({i, torch.rand(10), torch.rand(10)}))
      local o = firstElement(module:forward({i, torch.rand(10), torch.rand(10)}))
      mytester:assertgt(torch.norm(i - o), precision, 'error on non batch forward for ' .. name)
      mytester:assertlt(torch.norm(e - o), precision, 'error on non batch forward for ' .. name)
      local i = torch.zeros(10)
      local o = firstElement(module:forward({i, torch.rand(10), torch.rand(10)}))
      mytester:assertlt(torch.norm(i - o), precision, 'error on non batch forward for ' .. name)
      -- batch forward
      local i = torch.rand(5, 10)
      local e = firstElement(recurrent:forward({i, torch.rand(5, 10), torch.rand(5, 10)}))
      local o = firstElement(module:forward({i, torch.rand(5, 10), torch.rand(5, 10)}))
      mytester:assertgt(torch.norm(i - o), precision, 'error on batch forward for ' .. name)
      mytester:assertlt(torch.norm(e - o), precision, 'error on batch forward for ' .. name)
      local i = torch.zeros(5, 10)
      local o = firstElement(module:forward({i, torch.rand(5, 10), torch.rand(5, 10)}))
      mytester:assertlt(torch.norm(i - o), precision, 'error on batch forward for ' .. name)
      local i = torch.Tensor({{0, 0, 0}, {1, 2, 5}})
      -- clone r because it will be update by module:forward call
      local r = firstElement(recurrent:forward({i, torch.rand(2, 3), torch.rand(2, 3)})):clone()
      local o = firstElement(module:forward({i, torch.rand(2, 3), torch.rand(2, 3)}))
      mytester:assertgt(torch.norm(r - o), precision, 'error on batch forward for ' .. name)
      r[1]:zero()
      mytester:assertlt(torch.norm(r - o), precision, 'error on batch forward for ' .. name)

      -- check gradients
      local jac = nn.Jacobian
      local sjac = nn.SparseJacobian
      -- Note: testJacobian doesn't support table inputs or outputs
      -- Use a SplitTable and SelectTable to adapt module
      local module = nn.Sequential()
      module:add(nn.SplitTable(1))
      module:add(nn.MaskZero(recurrent, 1))
      if name == 'lstm' then module:add(nn.SelectTable(1)) end

      local input = torch.rand(name == 'lstm' and 3 or 2, 10)
      local err = jac.testJacobian(module, input)
      mytester:assertlt(err, precision, 'error on state for ' .. name)
      -- IO
      local ferr,berr = jac.testIO(module,input)
      mytester:asserteq(ferr, 0, torch.typename(module) .. ' - i/o forward err for ' .. name)
      mytester:asserteq(berr, 0, torch.typename(module) .. ' - i/o backward err for ' .. name)
      -- batch
      -- rebuild module to avoid correlated tests
      local module = nn.Sequential()
      module:add(nn.SplitTable(1))
      module:add(nn.MaskZero(recurrent, 1))
      if name == 'lstm' then module:add(nn.SelectTable(1)) end

      local input = torch.rand(name == 'lstm' and 3 or 2, 5, 10)
      local err = jac.testJacobian(module,input)
      mytester:assertlt(err, precision, 'batch error on state for ' .. name)
   end
end

local function forwardbackward(module, criterion, input, expected)
  local output = module:forward(input)
  criterion:forward(output, expected)
  module:zeroGradParameters()
  module:backward(input, criterion:backward(output, expected))
  module:updateParameters(1)
  return output
end

function rnntest.LookupTableMaskZero()
   local batchSize = math.random(5, 10)
   local outputSize = math.random(5, 10)
   local indexSize = batchSize

   local m1 = nn.LookupTable(indexSize, outputSize)
   local m2 = nn.LookupTableMaskZero(indexSize, outputSize)
   m2.weight:narrow(1, 2, indexSize):copy(m1.weight)
   local criterion = nn.MSECriterion()
   -- Zero padding will change averaging
   -- TODO create Criterion supporting padding
   criterion.sizeAverage = false

   -- verify that LookupTables have the same results (modulo zero padding)
   -- through multiple backpropagations
   for i=1, 10 do
      local input1 = torch.randperm(batchSize)
      local input2 = torch.zeros(batchSize + 2)
      input2:narrow(1, 1, batchSize):copy(input1)
      local expected1 = torch.rand(batchSize, outputSize)
      local expected2 = torch.rand(batchSize + 2, outputSize)
      expected2:narrow(1, 1, batchSize):copy(expected1)
      local o1 = forwardbackward(m1, criterion, input1, expected1)
      local o2 = forwardbackward(m2, criterion, input2, expected2)
      -- output modulo zero index should be the same
      mytester:assertlt(torch.norm(o1 - o2:narrow(1, 1, batchSize), 2), precision)
      -- zero index should yield zero vector
      mytester:assertlt(o2[batchSize + 1]:norm(2), precision)
      mytester:assertlt(o2[batchSize + 2]:norm(2), precision)
      -- weights should be equivalent
      mytester:assertlt(torch.norm(m1.weight - m2.weight:narrow(1, 2, indexSize), 2), precision)
  end
end

function rnn.test(tests)
   mytester = torch.Tester()
   mytester:add(rnntest)
   math.randomseed(os.time())
   mytester:run(tests)
end
