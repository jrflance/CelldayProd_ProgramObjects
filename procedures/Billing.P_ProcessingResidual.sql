--liquibase formatted sql

--changeset melissarios:21310416 stripComments:false runOnChange:true endDelimiter:/
-- noqa: disable=all
-- =============================================
--             :
--      Author : Jacob Lowe
--             :
--     Created : 2017-07-04
--             :
-- Description : Create Residual Orders
--  JL20170808 : Updated Order Types
--  JL20170824 : Updated for Tracfone & Create table to hold Process ID's to process
--  JL20170921 : Updated for Addon Logic to solve invoice issue.
--  JL20170927 : Added insert into PaymentOrders
--  LZ20171031 : fix multi spiff debit issue
--  JL20171206 : Add check to verify record exists in tblBPProductMapping
--  LZ20171220 : Fix update balance issue
--  JL20171221 : Add Support for Email Queue Table
--  JL20180131 : hard coded verizon carrier id
--  JL20180307 : Fix Due Date for MA and minor maintenance
--  JL20180312 : Removed Spiff Debit
--  JL20180330 : Fix Parent Company and Add Tsys
--  JL20180406 : Fix issue with MA Due Date
--  JL20180516 : Update ordertype case statement
--  JL20180517 : Added Parent Company 9
--  JL20191017 : Added distinct to paymentorder table insert
--  MR20200326 : Added "Truncate table billing.tblEmailQueue"
--			   : Added HVN logic.
--  MR20200708 : Removed the Truncate email queue table and updated the MERGE statment by removed the extra additions and added "WHEN NOT MATCHED BY SOURCE THEN DELETE"
--  MR20210201 : Changed the email section to a simple Truncate and Insert script.
--			   : Added the #Withholding section specific to the January run.
--	MR20210202 : Commented out the #Withholding section so as not to run without updating for February.
--  MR20220429 : Added condition of "AND mt.ParentCompanyID = 5" to the HVN sections.
--			   : Changed the insert into @ToCreate to be IsUnique to 1 rather than 0.
--			   : added the column "ParentCompanyID" into the table #return in order to use it on the INSERT INTO dbo.order_commission section in order to eliminate duplicate entries when more than one file of various vendors is processed at a time.
--	MR20220729 : added truncate statement for email table and restricted on filled, processed, non-void
--  MR20231122 : added Gen Mobile residual parent company id. And added a restriction to verizon for entering data into tblEmailQueue table.
--  MR20240415 : added Cricket and MobileX parent company ids.
-- =============================================
-- noqa: enable=all
ALTER PROCEDURE [Billing].[P_ProcessingResidual]
AS
BEGIN TRY
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    DECLARE @Getdate DATETIME = GETDATE();

    IF OBJECT_ID('tempdb..#BPProcessTypeID') IS NOT NULL
        BEGIN
            DROP TABLE #BPProcessTypeID;
        END;

    CREATE TABLE #BPProcessTypeID
    (
        ID INT
    );
    INSERT INTO #BPProcessTypeID
    (
        ID
    )
    SELECT BPProcessTypeID
    FROM Billing.tblBPProcessType
    WHERE Sproc = 'P_ProcessingResidual';

    UPDATE bp
    SET
        bp.BPStatusID = 10, --If missing from tblBPProductMapping
        bp.StatusUpdated = @Getdate
    FROM Billing.tblBillingPayments AS bp
    JOIN #BPProcessTypeID AS bppt
        ON bppt.ID = bp.BPProcessTypeID
    WHERE
        bp.BPStatusID = 0
        AND
        (
            (ISNULL(bp.ParentCompanyID, 0) NOT IN (2, 4, 5, 6, 9, 10, 12, 13))	--MR20231122 --MR20240415
            OR (
                NOT EXISTS
                (
                    SELECT 1
                    FROM Billing.tblBPProductMapping AS bppm
                    JOIN dbo.Carrier_ID AS c
                        ON c.ID = bppm.CarrierID
                    WHERE
                        bppm.BPProcessTypeID = bp.BPProcessTypeID
                        AND c.ParentCompanyId = bp.ParentCompanyId
                )
            )
        );

    ; WITH CTE AS (
        SELECT bp.BillingPaymentID
        FROM Billing.tblBillingPayments AS bp
        JOIN Billing.tblBPMAAmount AS ma
            ON ma.BillingPaymentID = bp.BillingPaymentID
        JOIN #BPProcessTypeID AS bpptid
            ON bp.BPProcessTypeID = bpptid.ID
        WHERE
            bp.MerchantAmount = 0
            AND bp.BPStatusID = 0
        GROUP BY bp.BillingPaymentID
        HAVING SUM(ISNULL(ma.Amount, 0)) = 0
    )
    UPDATE bp
    SET
        bp.BPStatusID = 1, -- If pay = 0 and ma pay = 0, mark as complete
        bp.StatusUpdated = @Getdate
    FROM Billing.tblBillingPayments AS bp
    JOIN CTE AS t
        ON t.BillingPaymentID = bp.BillingPaymentID;

    IF OBJECT_ID('tempdb..#ProcessTable') IS NOT NULL
        BEGIN
            DROP TABLE #ProcessTable;
        END;

    SELECT
        bp.BillingPaymentID,
        bp.AccountID,
        bp.MerchantAmount,
        bp.ParentCompanyID,
        bp.BPProcessTypeID
    INTO #ProcessTable
    FROM [Billing].[tblBillingPayments] AS bp
    JOIN #BPProcessTypeID AS bpptid
        ON bp.BPProcessTypeID = bpptid.ID
    WHERE bp.BPStatusID = 0;
    --AND bp.MerchantAmount <> 0;

    IF OBJECT_ID('tempdb..#MerchantTable') IS NOT NULL
        BEGIN
            DROP TABLE #MerchantTable;
        END;

    SELECT
        AccountID,
        BPProcessTypeID,
        ParentCompanyID,
        SUM(MerchantAmount) AS [MerchantAmount]
    INTO #MerchantTable
    FROM #ProcessTable
    GROUP BY
        AccountID,
        BPProcessTypeID,
        ParentCompanyID;

    --------------------------------------------for HVN accounts--------------------------MR20200326-------------------------------------
    UPDATE mt
    SET mt.MerchantAmount = 0.00
    FROM #MerchantTable AS mt
    WHERE mt.AccountID IN (
        130484, 126122, 126121, 124476, 124480, 127687, 130479, 130480, 130481, 130482, 130483, 130485,
        130486, 130487, 130488, 130489, 130502, 130503, 130504, 130505, 127691, 124456, 124457, 124458,
        124459, 124462, 124468, 124470, 124475, 124477, 124478, 124479, 124481, 126188, 126190, 126191,
        126192, 124460, 124461, 124464, 124466, 124472, 124474, 127688, 124469
    )
    AND mt.ParentCompanyID = 5;--MR20220429
    ------------------------------------------------------------------------------------------------------------------------------

    IF OBJECT_ID('tempdb..#MATable') IS NOT NULL
        BEGIN
            DROP TABLE #MATable;
        END;

    SELECT
        ma.MAAccountId,
        pt.AccountID,
        SUM(ma.Amount) AS [MAAmount],
        pt.ParentCompanyID		--MR20220429
    INTO #MATable
    FROM #ProcessTable AS pt
    JOIN Billing.tblBPMAAmount AS ma
        ON ma.BillingPaymentID = pt.BillingPaymentID
    GROUP BY
        ma.MAAccountId,
        pt.AccountID,
        pt.ParentCompanyID		--MR20220429

    -------------------------------------------------------------------------------- MR20200326
    INSERT INTO #MATable				--for account 2 to get HVN's amount
    (
        MAAccountId,
        AccountID,
        MAAmount,
        ParentCompanyID			--MR20220429
    )

    SELECT
        2 AS MAAccountId,
        pt.AccountID,
        SUM(pt.MerchantAmount) AS MAAmount,
        5 AS ParentCompanyID		--MR20220429
    FROM #ProcessTable AS pt
    WHERE
        pt.AccountID IN (
            130484, 126122, 126121, 124476, 124480, 127687, 130479, 130480, 130481, 130482, 130483, 130485,
            130486, 130487, 130488, 130489, 130502, 130503, 130504, 130505, 127691, 124456, 124457, 124458,
            124459, 124462, 124468, 124470, 124475, 124477, 124478, 124479, 124481, 126188, 126190, 126191,
            126192, 124460, 124461, 124464, 124466, 124472, 124474, 127688, 124469
        )
        AND pt.ParentCompanyID = 5			--MR20220429
    GROUP BY pt.AccountID;
    --------------------------------------------------------------------------------


    ---*********************************************************************************************************************************


    DECLARE @ToCreate ORDERFULLDETAILTBLWFLG;

    INSERT INTO @ToCreate
    (
        Account_ID,
        CustomerID,
        SHIPTO,
        USERID,
        OrderType_Id,
        RefOrderNo,
        DateDue,
        CreditTermID,
        DiscountClassID,
        DateFrom,
        DateFilled,
        OrderTotal,
        Process,
        Filled,
        Void,
        Product_ID,
        ProductName,
        SKU,
        PRICE,
        DiscAmount,
        FEE,
        Tracking,
        User_IPAddress,
        IsUnique
    )
    SELECT
        pt.AccountID,
        a.Customer_ID,
        a.ShipTo,
        a.User_ID,
        CASE a.AccountType_ID
            WHEN 11
                THEN
                    38
            ELSE
                28
        END AS [OrderType_ID],
        pt.AccountID AS [OrderNo],
        dbo.fnCalculateDueDate(pt.AccountID, @Getdate) AS [DateDue],
        a.CreditTerms_ID,
        a.DiscountClass_ID,
        @Getdate AS [DateFrom], --DateOrdered
        @Getdate AS [DateFilled],
        (pt.MerchantAmount * (-1)) AS [OrderTotal],
        1 AS [Process],
        1 AS [filled],
        0 AS [void],
        p.Product_ID,
        p.Name,
        '' AS [SKU],
        (pt.MerchantAmount * (-1)) AS [Price],
        0 AS [DiscAmount],
        0 AS [Fee],
        '192.168.151.9' AS [Tracking],
        '192.168.151.9' AS [User_IPAddress],
        1 AS [IsUnique]		--MR20220429
    FROM #MerchantTable AS pt
    JOIN dbo.Account AS a
        ON a.Account_ID = pt.AccountID
    JOIN [Billing].[tblBPProductMapping] AS bppm
        ON
            bppm.BPProcessTypeID = pt.BPProcessTypeID
            AND bppm.CarrierID = CASE pt.ParentCompanyID
                WHEN 2
                    THEN
                        8
                WHEN 4
                    THEN
                        23
                WHEN 5
                    THEN
                        7
                WHEN 6
                    THEN
                        259
                WHEN 9
                    THEN
                        277
                WHEN 10  --MR20231122
                    THEN
                        270
                WHEN 12
                    THEN --MR20240415
                        56
                WHEN 13
                    THEN --MR20240415
                        302
            END
    JOIN dbo.Products AS p
        ON bppm.ProductID = p.Product_ID;


    IF OBJECT_ID('tempdb..#return') IS NOT NULL
        BEGIN
            DROP TABLE #return;
        END;

    CREATE TABLE #return
    (
        ID INT,
        Order_No INT
    );

    INSERT INTO #return
    EXEC OrderManagment.P_OrderManagment_Build_Full_Order_table_wTracking_IP_inBatch
        @OrderDetail = @ToCreate, -- OrderFullDetailTblwFlg
        @Batchsize = 1000;        -- int

    UPDATE n
    SET n.AuthNumber = NULL
    FROM dbo.Order_No AS n
    JOIN #return AS r
        ON r.Order_No = n.Order_No;

    --Existing Logic ----------- For support of prepaid Recon
    UPDATE n
    SET n.Paid = 1
    FROM dbo.Order_No AS n
    JOIN #return AS r
        ON r.Order_No = n.Order_No
    WHERE n.OrderType_ID = 38;

    --Existing Logic ----------- Support for Invoices
    UPDATE o
    SET o.Addons = CAST(DATEPART(MONTH, @Getdate) AS VARCHAR(2)) + CAST(DATEPART(YEAR, @Getdate) AS VARCHAR(4))
    FROM dbo.Orders AS o
    JOIN #return AS r
        ON r.ID = o.ID;

    ; WITH X AS (
        SELECT
            o.Account_ID,
            SUM(ISNULL(o.OrderTotal, 0)) AS [TotalChange]
        FROM #return AS r
        JOIN dbo.Order_No AS o
            ON o.Order_No = r.Order_No
        GROUP BY o.Account_ID
    )
    UPDATE a
    SET
        AvailableTotalCreditLimit_Amt = a.AvailableTotalCreditLimit_Amt - X.TotalChange,
        AvailableDailyCreditLimit_Amt = a.AvailableDailyCreditLimit_Amt - X.TotalChange
    FROM dbo.Account AS a
    JOIN X
        ON X.Account_ID = a.Account_ID;

    --INSERT  INTO OrderManagment.tblProviderReference
    --        ( OrderNo ,
    --          ReferenceID ,
    --          AccountID ,
    --          Source
    --        )
    --        SELECT  fp.NewOrder ,
    --                fp.BillingPaymentID ,
    --                fp.AccountID ,
    --                pc.ParentCompanyName + ' Residual'
    --        FROM    #finalProcessing fp
    --                JOIN dbo.tblParentCompany pc ON pc.ParentCompanyId = fp.ParentCompanyId;

    ------------- MA Commission

    ALTER TABLE #Return					--MR20220429
    ADD ParentCompanyID INT NULL

    UPDATE r							--MR20220429
    SET r.ParentCompanyID = c.ParentCompanyId
    FROM #Return AS r
    JOIN dbo.orders AS d
        ON r.ID = d.ID
    JOIN Products.tblProductCarrierMapping AS pcm
        ON pcm.ProductId = d.Product_ID
    JOIN dbo.Carrier_ID AS c
        ON c.ID = pcm.CarrierId


    DECLARE @Tomorrow DATETIME = DATEADD(DAY, 1, @Getdate);

    INSERT INTO dbo.Order_Commission
    (
        Order_No,
        Orders_ID,
        Account_ID,
        Commission_Amt,
        Datedue,
        InvoiceNum
    )
    SELECT
        r.Order_No,
        r.ID,
        mat.MAAccountId,
        mat.MAAmount,
        CAST(DATEADD(D, 6 - ((DATEPART(DW, @Tomorrow) + @@DATEFIRST) % 7), @Tomorrow) AS DATE) AS Datedue,
        NULL AS [InvoiceNum]
    FROM #MATable AS mat
    JOIN dbo.Order_No AS n
        ON mat.AccountID = n.Account_ID
    JOIN #return AS r
        ON
            n.Order_No = r.Order_No
            AND r.ParentCompanyID = mat.ParentCompanyID;


    ------------- MA Commission

    INSERT INTO Billing.tblBPPaymentOrder
    (
        BillingPaymentID,
        PaymentOrderNo
    )
    SELECT DISTINCT
        pt.BillingPaymentID,
        n.Order_No
    FROM #return AS r
    JOIN dbo.Order_No AS n
        ON n.Order_No = r.Order_No
    JOIN #ProcessTable AS pt
        ON
            pt.AccountID = n.Account_ID
            AND pt.ParentCompanyID = r.ParentCompanyID;		--MR20220429
    ------------- Email Queue table --update MR20210201

    IF (SELECT COUNT(1) FROM billing.tblEmailQueue) > 0  --MR20220729
        BEGIN
            TRUNCATE TABLE billing.tblEmailQueue
        END;

    INSERT INTO billing.tblEmailQueue
    (
        Account_ID,
        Carrier_ID,
        PaymentType,
        NumOfTrx,
        Amount
    )
    SELECT
        n.Account_ID,
        pcm.CarrierId,
        'Residual' AS PaymentType,
        1 AS NumOfTrx,
        (SUM(ISNULL(o.Price, 0)) * (-1)) AS Amount
    FROM #return AS r
    JOIN dbo.Order_No AS n
        ON
            r.Order_No = n.Order_No
            AND n.Filled = 1
            AND n.Process = 1
            AND n.Void = 0
    JOIN dbo.Orders AS o
        ON
            o.ID = r.ID
            AND n.Order_No = o.Order_No
    JOIN Products.tblProductCarrierMapping AS pcm
        ON o.Product_ID = pcm.ProductId
    WHERE
        o.Price <> 0
        AND pcm.CarrierId = 7	--verizon
    GROUP BY
        n.Account_ID,
        pcm.CarrierId


    --JL20180312 Remove Spiff Debit Per Olimpia
    ----------------------Start Spiff Debit
    --;
    --DECLARE @SpiffDebit udt_IDMapping;

    --INSERT INTO @SpiffDebit
    --(
    --    ID_A,
    --    ID_B
    --)
    --SELECT T.BillingPaymentID,
    --       T.ID
    --FROM
    --(
    --    SELECT pt.BillingPaymentID,
    --           r.ID,
    --           ROW_NUMBER() OVER (PARTITION BY r.ID ORDER BY pt.BillingPaymentID ASC) RK
    --    FROM #return r
    --        JOIN dbo.Order_No n
    --            ON n.Order_No = r.Order_No
    --        JOIN #ProcessTable pt
    --            ON pt.AccountID = n.Account_ID
    --) T
    --WHERE T.RK = 1;

    --EXEC Billing.P_CreateSpiffDebit @OrderNo = @SpiffDebit; -- IDs

    -----------------------End Spiff Debits

    UPDATE bp
    SET
        bp.BPStatusID = 1,
        bp.StatusUpdated = @Getdate
    FROM Billing.tblBillingPayments AS bp
    JOIN #ProcessTable AS po
        ON po.BillingPaymentID = bp.BillingPaymentID
    WHERE bp.BPStatusID = 0;

END TRY
BEGIN CATCH
    THROW;
END CATCH;
-- noqa: disable=all
/
